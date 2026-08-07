import Foundation

/// Traduction `Recurrence` → `StartCalendarInterval`, et fabrication du `.plist` —
/// **lot L2**. Entièrement **PUR** : aucun effet de bord, aucun accès disque.
/// (Seule exception assumée : `probe()`, qui est le harnais d'auto-test et délègue ses
/// écritures à `SchedulerService.dryRunProbe(_:)`, dans un dossier jetable.)
///
/// `nextFireDate` vit délibérément dans ce fichier : « ce que l'UI promet » et « ce que
/// launchd fait » doivent sortir de la même tête.
///
/// ## Les règles du man, vérifiées
/// - *« Missing arguments are considered to be wildcard »* → on n'émet **que** les clés
///   qui contraignent.
/// - *« If both Day and Weekday are specified, then the job will be started if either one
///   matches »* — c'est un **OU**. Un mensuel qui émettrait `Weekday` par inadvertance
///   tirerait une fois par semaine en plus. **Invariant à vérifier en premier :
///   `calendarIntervals(for: .monthly(…))` ne contient JAMAIS la clé `Weekday`.**
/// - launchd **ne clampe pas** : `Day: 31` ne se déclenche jamais en février, avril,
///   juin, septembre ni novembre. D'où le plafond à 28 (`Recurrence.allowedMonthDays`).
/// - *« StartInterval and StartCalendarInterval are not aware of each other »* : les
///   mélanger produirait deux planificateurs indépendants. **On n'émet jamais `StartInterval`.**
///
/// ⚠️ Corollaire direct de la règle du joker, et c'est le pire piège du fichier : un
/// **dictionnaire vide** dans `StartCalendarInterval` signifie « tous les champs en
/// joker », donc **toutes les minutes**. Toute entrée produite ici porte donc au minimum
/// `Hour` + `Minute`, et le cas « rien à planifier » se rend par un **tableau vide**
/// (aucune occurrence), jamais par un dict vide.
///
/// ## Le plist généré
/// Par `PropertyListSerialization.data(fromPropertyList:format:.xml)` — **jamais** de
/// template de chaîne (même raisonnement que `JSONSerialization` dans `IDEHost`).
/// - **`RunAtLoad = false` impérativement** : `bootstrap` a lieu à chaque ouverture de
///   session ET à chaque réinstallation du plist (donc à chaque édition). `true`
///   lancerait un agent à chaque login et à chaque clic sur Enregistrer. Ce n'est PAS un
///   mécanisme de rattrapage — c'est le contresens à ne pas faire.
/// - **Pas de `KeepAlive`** : un run qui échoue ne doit surtout pas être relancé en boucle.
/// - launchd ne développe pas `$HOME` dans `EnvironmentVariables` → chemins littéraux
///   absolus, construits depuis `NSHomeDirectory()`.
enum LaunchAgentPlist {

    /// Clé d'environnement lue par le runner pour distinguer un tir launchd d'un
    /// « Lancer maintenant » (§6.7 : seul le premier notifie).
    static let triggerEnvironmentKey = "POTOF_SCHEDULE_TRIGGER"
    static let launchdTriggerValue = "launchd"

    /// Drapeau du mode headless. **Doit rester identique** à celui reconnu par
    /// `main.swift` avant `NSApplication` : c'est le seul lien entre le plist écrit
    /// aujourd'hui et le binaire qui l'exécutera dans six mois.
    static let runScheduleFlag = "--run-schedule"

    /// Variable d'environnement lue **uniquement par `probe()`** pour opérer dans un
    /// dossier jetable choisi par l'appelant. Absente ⇒ dossier temporaire du système.
    static let probeRootEnvironmentKey = "POTOF_SCHED_PROBE_ROOT"

    // MARK: - Recurrence → StartCalendarInterval

    /// ```swift
    /// case .everyNHours(let h, let anchor, let m):
    ///     stride(from: anchor % h, to: 24, by: h).map { ["Hour": $0, "Minute": m] }
    /// ```
    /// `{hours: 6, anchorHour: 2, minute: 0}` → `[{Hour:2},{Hour:8},{Hour:14},{Hour:20}]`.
    ///
    /// Hebdomadaire à 7 jours ⇒ **une seule entrée** `{Hour, Minute}` au lieu de 7.
    static func calendarIntervals(for recurrence: Recurrence) -> [[String: Int]] {
        switch recurrence {

        case .everyNHours(let hours, let anchorHour, let minute):
            // `hours` est validé côté modèle (diviseur de 24), mais `schedules.json` est
            // un fichier que l'on peut éditer à la main : un pas ≤ 0 ferait boucler
            // `stride` indéfiniment et un `% 0` tuerait le process.
            let step = max(1, hours)
            let start = ((anchorHour % step) + step) % step     // ancrage négatif → positif
            return stride(from: start, to: 24, by: step).map { ["Hour": $0, "Minute": minute] }

        case .daily(let hour, let minute):
            return [["Hour": hour, "Minute": minute]]

        case .weekly(let weekdays, let hour, let minute):
            let days = weekdays.filter { Recurrence.allowedWeekdays.contains($0) }.sorted()
            // Aucun jour : `validate()` le refuse en amont. Ici on rend un tableau VIDE
            // (aucune occurrence) — surtout pas un dict sans clé, qui vaudrait « toutes
            // les minutes » pour launchd.
            if days.isEmpty { return [] }
            // 7 jours = quotidien : on omet `Weekday` (joker) plutôt que d'émettre
            // 7 entrées équivalentes.
            if days.count == 7 { return [["Hour": hour, "Minute": minute]] }
            return days.map { ["Weekday": $0, "Hour": hour, "Minute": minute] }

        case .monthly(let day, let hour, let minute):
            // ⚠️ JAMAIS de clé `Weekday` ici : `Day` + `Weekday` est un OU côté launchd,
            // et le mensuel tirerait une fois par semaine en plus.
            return [["Day": day, "Hour": hour, "Minute": minute]]
        }
    }

    // MARK: - Plist

    static func dictionary(for schedule: Schedule, executablePath: String) -> [String: Any] {
        // Un seul fichier pour stdout et stderr : c'est la forme des 4 plists déjà en
        // production sur le poste, et un run entrelacé se lit dans l'ordre.
        let logPath = SchedulePaths.launchdLogFile(scheduleID: schedule.id).path

        return [
            "Label": schedule.launchAgentLabel,
            // Aucun texte utilisateur n'atterrit jamais ici : ni le prompt, ni le nom.
            // Le plist ne porte qu'un UUID, tout le reste vit dans `schedules.json`.
            "ProgramArguments": [executablePath, runScheduleFlag, schedule.id.uuidString],
            "StartCalendarInterval": calendarIntervals(for: schedule.recurrence),
            // Impératif. Voir l'en-tête : `bootstrap` a lieu à chaque login ET à chaque
            // réinstallation ⇒ `true` lancerait un agent à chaque fois.
            "RunAtLoad": false,
            "EnvironmentVariables": [
                // Le PATH par défaut sous launchd est `/usr/bin:/bin:/usr/sbin:/sbin` :
                // sans ça, `superset` est introuvable. Chemins littéraux — launchd ne
                // développe pas `$HOME`.
                "PATH": SchedulePaths.searchPath,
                triggerEnvironmentKey: launchdTriggerValue
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath
            // Pas de `KeepAlive`, pas de `StartInterval` : voir l'en-tête.
        ]
    }

    static func data(for schedule: Schedule, executablePath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary(for: schedule, executablePath: executablePath),
            format: .xml,
            options: 0)
    }

    // MARK: - Libellé humain

    /// Ordre d'affichage français : L M M J V S D (le modèle, lui, indexe 0 = dimanche).
    private static let weekdayDisplayOrder = [1, 2, 3, 4, 5, 6, 0]
    private static let weekdayNames =
        ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]

    private static func hhmm(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Libellé français d'une cadence (« tous les jours à 10:00 », « les lundi et jeudi à 9:15 »).
    static func humanDescription(_ recurrence: Recurrence) -> String {
        switch recurrence {

        case .everyNHours(let hours, _, let minute):
            let times = calendarIntervals(for: recurrence)
                .map { hhmm($0["Hour"] ?? 0, $0["Minute"] ?? minute) }
            if hours <= 1 {
                return "toutes les heures, à la minute \(String(format: "%02d", minute))"
            }
            let shown = times.count <= 6
                ? times.joined(separator: ", ")
                : times.prefix(3).joined(separator: ", ") + ", …"
            return "toutes les \(hours) h (\(shown))"

        case .daily(let hour, let minute):
            return "tous les jours à \(hhmm(hour, minute))"

        case .weekly(let weekdays, let hour, let minute):
            let time = hhmm(hour, minute)
            let days = weekdays.filter { Recurrence.allowedWeekdays.contains($0) }
            if days.isEmpty { return "aucun jour sélectionné (ne se déclenchera jamais)" }
            if days.count == 7 { return "tous les jours à \(time)" }
            if days == [1, 2, 3, 4, 5] { return "du lundi au vendredi à \(time)" }
            if days == [0, 6] { return "le week-end à \(time)" }
            let ordered = days
                .sorted { (weekdayDisplayOrder.firstIndex(of: $0) ?? 0)
                        < (weekdayDisplayOrder.firstIndex(of: $1) ?? 0) }
                .map { weekdayNames[$0] }
            if ordered.count == 1 { return "tous les \(ordered[0])s à \(time)" }
            let list = ordered.dropLast().joined(separator: ", ") + " et " + (ordered.last ?? "")
            return "les \(list) à \(time)"

        case .monthly(let day, let hour, let minute):
            let dayLabel = day == 1 ? "1er" : "\(day)"
            return "le \(dayLabel) de chaque mois à \(hhmm(hour, minute))"
        }
    }

    // MARK: - Prochaine occurrence

    /// launchd indexe les jours `0 = dimanche … 6 = samedi` (et accepte `7` pour
    /// dimanche) ; `Calendar` indexe `1 = dimanche … 7 = samedi`. Le décalage d'un cran
    /// est la seule conversion du fichier — la rater décalerait toutes les prévisions
    /// d'affichage d'un jour, sans que le plist, lui, soit faux.
    private static func matchingComponents(_ interval: [String: Int]) -> DateComponents {
        var components = DateComponents()
        components.second = 0                       // sinon la seconde reste un joker
        if let hour = interval["Hour"] { components.hour = hour }
        if let minute = interval["Minute"] { components.minute = minute }
        if let day = interval["Day"] { components.day = day }
        if let weekday = interval["Weekday"] { components.weekday = (weekday % 7) + 1 }
        return components
    }

    /// Prochaine occurrence **strictement après** `after`, ou `nil` si la cadence ne se
    /// déclenche jamais (aucun jour coché). Calculée à partir des mêmes intervalles que
    /// ceux écrits dans le plist : c'est ce qui garantit que l'UI ne promet pas autre
    /// chose que ce que launchd fera.
    static func nextFireDate(_ recurrence: Recurrence, after: Date, calendar: Calendar) -> Date? {
        let intervals = calendarIntervals(for: recurrence)
        guard !intervals.isEmpty else { return nil }
        return intervals.compactMap {
            calendar.nextDate(
                after: after,
                matching: matchingComponents($0),
                matchingPolicy: .nextTime,
                direction: .forward)
        }.min()
    }

    /// Les `count` prochaines occurrences, en repartant à chaque fois de la précédente.
    static func nextFireDates(_ recurrence: Recurrence, after: Date,
                              count: Int, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var cursor = after
        for _ in 0..<max(0, count) {
            guard let next = nextFireDate(recurrence, after: cursor, calendar: calendar) else { break }
            dates.append(next)
            cursor = next
        }
        return dates
    }

    // MARK: - Auto-test (`--sched-selftest plist`)

    /// Les 4 cadences, avec des UUID **figés** : les noms de fichiers produits par le
    /// probe sont ainsi stables d'une exécution à l'autre (diffables, lintables).
    static func probeSchedules() -> [Schedule] {
        func make(_ uuid: String, _ name: String, _ recurrence: Recurrence) -> Schedule {
            Schedule(
                id: UUID(uuidString: uuid) ?? UUID(),
                name: name,
                action: .supersetAgent(
                    agentRef: "dc0a5495-9d1e-45ef-a3c9-b63949e6a48f",
                    effort: nil,
                    prompt: "Prompt d'exemple du probe L2 — assez long pour passer validate()."),
                recurrence: recurrence,
                target: .permanentWorkspace(
                    projectID: "6ccf66bf-1780-40fc-b7e9-256fcd01c51c",
                    projectName: "Shopify-Apps",
                    workspaceName: "Veille Sentry",
                    branch: "veille-sentry",
                    baseBranch: "main",
                    refreshWorktree: true))
        }
        return [
            make("11111111-1111-4111-8111-111111111111", "Toutes les 6 h",
                 .everyNHours(hours: 6, anchorHour: 2, minute: 0)),
            make("22222222-2222-4222-8222-222222222222", "Quotidien 10:00",
                 .daily(hour: 10, minute: 0)),
            make("33333333-3333-4333-8333-333333333333", "Hebdo L-V 10:00",
                 .weekly(weekdays: [1, 2, 3, 4, 5], hour: 10, minute: 0)),
            make("44444444-4444-4444-8444-444444444444", "Mensuel le 1er 09:30",
                 .monthly(day: 1, hour: 9, minute: 30))
        ]
    }

    private static func frenchFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM yyyy 'à' HH:mm"
        return formatter
    }

    static func probe() -> String {
        var out: [String] = []
        var failures = 0

        func check(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            out.append("  [\(ok ? "OK  " : "ÉCHEC")] \(label)")
        }

        let calendar = Calendar.current
        let now = Date()
        let formatter = frenchFormatter()
        // Chemin réaliste d'app bundlée (avec son espace) pour les plists imprimés :
        // le probe tourne en `swift run`, où le vrai binaire est dans `.build/debug/`.
        let executablePath = NSHomeDirectory()
            + "/Applications/Potof Toolkit.app/Contents/MacOS/potof-toolkit"

        out.append("LaunchAgentPlist.probe — lot L2")
        out.append("binaire du plist imprimé : \(executablePath)")
        out.append("binaire courant          : \(SchedulePaths.hostExecutableURL.path)")
        out.append("canInstallLaunchAgents   : \(SchedulePaths.canInstallLaunchAgents)")
        out.append("maintenant               : \(formatter.string(from: now)) "
                   + "(\(TimeZone.current.identifier))")

        // ── 1. Les 4 cadences ────────────────────────────────────────────────────
        out.append("")
        out.append("══ 1. Les 4 cadences ═══════════════════════════════════════════")
        for schedule in probeSchedules() {
            let intervals = calendarIntervals(for: schedule.recurrence)
            out.append("")
            out.append("• \(schedule.name) — \(humanDescription(schedule.recurrence))")
            out.append("  StartCalendarInterval : \(intervals.count) entrée(s)")
            for interval in intervals {
                let body = interval.keys.sorted()
                    .map { "\($0): \(interval[$0] ?? 0)" }
                    .joined(separator: ", ")
                out.append("    { \(body) }")
            }
            out.append("  3 prochains déclenchements :")
            let upcoming = nextFireDates(schedule.recurrence, after: now, count: 3, calendar: calendar)
            if upcoming.isEmpty {
                out.append("    (aucun — cette cadence ne se déclenche jamais)")
            }
            for date in upcoming { out.append("    \(formatter.string(from: date))") }

            let xml: String
            do {
                let payload = try Self.data(for: schedule, executablePath: executablePath)
                xml = String(data: payload, encoding: .utf8) ?? "<non décodable>"
            } catch {
                failures += 1
                xml = "<ÉCHEC de sérialisation : \(error.localizedDescription)>"
            }
            // Marqueurs non indentés : `awk` peut extraire le bloc tel quel dans un
            // fichier et le passer à `plutil -lint`.
            out.append("===== BEGIN PLIST \(schedule.launchAgentLabel) =====")
            out.append(xml.trimmingCharacters(in: .newlines))
            out.append("===== END PLIST \(schedule.launchAgentLabel) =====")
        }

        // ── 2. Les invariants ────────────────────────────────────────────────────
        out.append("")
        out.append("══ 2. Invariants ═══════════════════════════════════════════════")

        let monthly = calendarIntervals(for: .monthly(day: 1, hour: 9, minute: 30))
        let monthlyKeys = Set(monthly.flatMap { $0.keys }).sorted()
        check(!monthlyKeys.contains("Weekday"),
              "un .monthly n'émet AUCUNE clé « Weekday » — clés vues : \(monthlyKeys.joined(separator: ", ")) "
              + "(Day + Weekday est un OU côté launchd)")
        check(monthly.count == 1 && monthly[0]["Day"] == 1,
              "un .monthly émet exactement 1 entrée, avec Day = 1")

        let every6 = calendarIntervals(for: .everyNHours(hours: 6, anchorHour: 2, minute: 0))
        let hours6 = every6.compactMap { $0["Hour"] }
        check(every6.count == 4, "everyNHours(6, ancre 2, minute 0) → 4 entrées (obtenu : \(every6.count))")
        check(hours6 == [2, 8, 14, 20], "…et Hour ∈ [2, 8, 14, 20] (obtenu : \(hours6))")
        check(every6.allSatisfy { $0["Minute"] == 0 }, "…et Minute = 0 partout")
        check(every6.allSatisfy { !$0.keys.contains("Weekday") && !$0.keys.contains("Day") },
              "…et aucune clé Weekday/Day parasite")

        let weekly7 = calendarIntervals(for: .weekly(weekdays: [0, 1, 2, 3, 4, 5, 6], hour: 10, minute: 0))
        check(weekly7.count == 1,
              "un weekly à 7 jours produit UNE seule entrée, pas 7 (obtenu : \(weekly7.count))")
        check(weekly7.first?.keys.contains("Weekday") == false,
              "…et cette entrée omet « Weekday » (joker = tous les jours)")

        let weekly5 = calendarIntervals(for: .weekly(weekdays: [1, 2, 3, 4, 5], hour: 10, minute: 0))
        check(weekly5.count == 5 && weekly5.compactMap { $0["Weekday"] } == [1, 2, 3, 4, 5],
              "un weekly L-V produit 5 entrées Weekday 1…5 (forme des plists com.potof.* en prod)")

        let weeklyEmpty = calendarIntervals(for: .weekly(weekdays: [], hour: 10, minute: 0))
        check(weeklyEmpty.isEmpty,
              "un weekly sans jour rend un TABLEAU vide, jamais un dict vide "
              + "(un dict vide = tous les champs en joker = toutes les minutes)")

        let allRecurrences: [Recurrence] = [
            .everyNHours(hours: 1, anchorHour: 0, minute: 0),
            .everyNHours(hours: 12, anchorHour: 7, minute: 45),
            .daily(hour: 0, minute: 0),
            .weekly(weekdays: [0], hour: 23, minute: 59),
            .monthly(day: 28, hour: 12, minute: 0)
        ]
        check(allRecurrences.allSatisfy { calendarIntervals(for: $0).allSatisfy { !$0.isEmpty } },
              "aucune cadence ne produit d'entrée vide")
        check(allRecurrences.allSatisfy {
                  calendarIntervals(for: $0).allSatisfy { $0["Hour"] != nil && $0["Minute"] != nil } },
              "toute entrée porte au minimum Hour + Minute")

        let sample = probeSchedules()[1]
        let dict = dictionary(for: sample, executablePath: executablePath)
        check(dict["RunAtLoad"] as? Bool == false, "RunAtLoad == false")
        check(dict["StartInterval"] == nil, "aucune clé StartInterval")
        check(dict["KeepAlive"] == nil, "aucune clé KeepAlive")
        check((dict["ProgramArguments"] as? [String])?.count == 3,
              "ProgramArguments = [binaire, \(runScheduleFlag), <uuid>] — aucun texte utilisateur")
        check((dict["ProgramArguments"] as? [String])?.last == sample.id.uuidString,
              "…et le 3ᵉ argument est bien l'UUID de la planification")
        let env = dict["EnvironmentVariables"] as? [String: String]
        check(env?["PATH"]?.hasPrefix(NSHomeDirectory()) == true,
              "PATH littéral absolu (launchd ne développe pas $HOME) : \(env?["PATH"] ?? "—")")
        check(env?[triggerEnvironmentKey] == launchdTriggerValue,
              "\(triggerEnvironmentKey) = \(launchdTriggerValue)")
        check((dict["StandardOutPath"] as? String) == (dict["StandardErrorPath"] as? String),
              "StandardOutPath == StandardErrorPath (un seul fichier, ordre préservé)")

        // Correspondance libellé UI ↔ intervalles : la promesse et le fait.
        let sixHours = Recurrence.everyNHours(hours: 6, anchorHour: 2, minute: 0)
        check(humanDescription(sixHours) == "toutes les 6 h (02:00, 08:00, 14:00, 20:00)",
              "humanDescription cohérent avec les intervalles : « \(humanDescription(sixHours)) »")

        // nextFireDate : la conversion d'index des jours est la seule vraie source d'erreur.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        // 2026-08-06 est un JEUDI.
        let thursday = utc.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 0, minute: 0))!
        let nextSunday = nextFireDate(.weekly(weekdays: [0], hour: 9, minute: 0),
                                      after: thursday, calendar: utc)
        let sundayComponents = nextSunday.map { utc.dateComponents([.year, .month, .day, .weekday], from: $0) }
        check(sundayComponents?.weekday == 1 && sundayComponents?.day == 9,
              "weekday launchd 0 (dimanche) → prochaine occurrence le dimanche 9/08/2026 "
              + "(obtenu : jour \(sundayComponents?.day ?? -1), weekday Calendar \(sundayComponents?.weekday ?? -1))")
        let nextSaturday = nextFireDate(.weekly(weekdays: [6], hour: 9, minute: 0),
                                        after: thursday, calendar: utc)
        check(nextSaturday.map { utc.component(.day, from: $0) } == 8,
              "weekday launchd 6 (samedi) → samedi 8/08/2026")
        let nextMonthly = nextFireDate(.monthly(day: 28, hour: 12, minute: 0),
                                       after: thursday, calendar: utc)
        check(nextMonthly.map { utc.component(.day, from: $0) } == 28,
              "monthly(28) → le 28 du mois courant")
        check(nextFireDate(.weekly(weekdays: [], hour: 9, minute: 0),
                           after: thursday, calendar: utc) == nil,
              "une cadence sans occurrence rend nil (et non une date inventée)")

        // ── 3. SchedulerService à sec ────────────────────────────────────────────
        out.append("")
        out.append("══ 3. SchedulerService en dry-run (launchctl court-circuité) ════")
        let dryRun = SchedulerService.dryRunProbe(probeSchedules())
        out.append(dryRun.report)
        failures += dryRun.failures

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) invariant(s) EN ÉCHEC.")
        return out.joined(separator: "\n")
    }
}
