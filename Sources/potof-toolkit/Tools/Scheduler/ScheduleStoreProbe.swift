import Foundation

/// Auto-test du stockage — `potof-toolkit --sched-selftest store`.
///
/// Opère **entièrement** dans un dossier jetable via `SchedulePaths.overrideRoot` : après
/// ce probe, `~/Library/Application Support/PotofToolkit/scheduler/` et
/// `~/Library/LaunchAgents` doivent être **inchangés**. C'est vérifié en fin de rapport.
///
/// Ce qu'il prouve, dans l'ordre : un aller-retour disque fidèle du format v2 (`Codable`
/// manuel de `Action` compris), la purge d'un `schedules.json` v1 (Superset) et le refus
/// de réécrire un fichier illisible, la validation par volet, le CRUD, la sémantique du
/// JSONL (append-only, deux lignes par run), et surtout **le pliage** — un `start` sans
/// `end` dont le pid est mort doit ressortir en `interrupted`, sans qu'aucun état n'ait à
/// être réconcilié sur disque.
enum ScheduleStoreProbe {

    /// Pid volontairement hors de portée (`kill(2)` → ESRCH) pour simuler un run mort en
    /// route : c'est la seule chose qui départage `running` de `interrupted`.
    private static let deadPID: Int32 = 999_999

    /// Copie d'une entrée Superset réelle du `schedules.json` v1 (2026-10-30).
    private static let legacyFile = """
    {
      "schedules" : [
        {
          "action" : {
            "agentRef" : "dc0a5495-9d1e-45ef-a3c9-b63949e6a48f",
            "effort" : null,
            "kind" : "supersetAgent",
            "prompt" : "Récupère les erreurs Sentry de la nuit et écris le rapport du jour."
          },
          "createdAt" : "2026-08-20T08:12:44Z",
          "enabled" : true,
          "id" : "3F0C2B1A-7D55-4E0B-9C61-2A4B8E9D1F70",
          "name" : "Sentry Report — Shopify apps",
          "recurrence" : { "hour" : 10, "kind" : "daily", "minute" : 0 },
          "target" : {
            "baseBranch" : "main",
            "branch" : "sentry-report",
            "kind" : "permanentWorkspace",
            "projectID" : "6ccf66bf-1780-40fc-b7e9-256fcd01c51c",
            "projectName" : "Shopify-Apps",
            "refreshWorktree" : true,
            "workspaceName" : "Sentry report"
          },
          "updatedAt" : "2026-09-02T07:30:00Z"
        }
      ],
      "version" : 1
    }
    """

    static func run() -> String {
        var out: [String] = []
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                out.append("  [OK  ] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                failures += 1
                out.append("  [ÉCHEC] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        // ── Dossier jetable ──────────────────────────────────────────────────────
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-sched-store-probe-\(UUID().uuidString)", isDirectory: true)
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = nil }
        let fm = FileManager.default
        let work = root.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        let realStore = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PotofToolkit/scheduler",
                                    isDirectory: true)
        let realStoreExistedBefore = fm.fileExists(atPath: realStore.path)

        let realLaunchAgents = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        /// Nos plists **déjà** présents dans le vrai dossier.
        ///
        /// ⚠️ Cet ensemble n'est pas censé être vide : dès que l'utilisateur crée une
        /// planification depuis l'app bundlée, il y en a. Ce que le probe doit prouver,
        /// c'est qu'il n'en **ajoute ni n'en retire aucun** — pas que le poste n'en a pas.
        func realPlists() -> Set<String> {
            let names = (try? fm.contentsOfDirectory(atPath: realLaunchAgents.path)) ?? []
            return Set(names.filter { $0.hasPrefix(SchedulerService.labelPrefix) })
        }
        let realPlistsBefore = realPlists()

        out.append("── ScheduleStore / RunLog — auto-test (format v2) ───────────────")
        out.append("Racine jetable : \(root.path)")
        out.append("isDryRun       : \(SchedulePaths.isDryRun)")
        out.append("")

        let store = ScheduleStore.shared
        let settings = work.appendingPathComponent("run.settings.json")
        try? Data("{}".utf8).write(to: settings)

        // ── 1. Aller-retour Codable ──────────────────────────────────────────────
        out.append("— format v2 —")
        let complet = Schedule(
            name: "Relevé Sentry — Shopify-Apps",
            folderPath: work.path,
            preScript: "git fetch --prune\ngit status --short",
            action: .claude(prompt: "Récupère les erreurs de la nuit et écris le rapport du jour.",
                            model: "haiku", effort: nil, settingsPath: settings.path),
            recurrence: .weekly(weekdays: [1, 4], hour: 9, minute: 15),
            timeoutMinutes: 45,
            requiredMCPServers: ["plugin:sentry-mcp:sentry", "n8n-prod"],
            // Secondes entières : l'ISO 8601 du fichier ne garde pas les fractions.
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_060))
        if let data = try? ScheduleStore.makeEncoder().encode(complet),
           let decoded = try? ScheduleStore.makeDecoder().decode(Schedule.self, from: data) {
            let json = String(decoding: data, as: UTF8.self)
            check("store.roundTrip", decoded == complet
                  && (json.contains("\"kind\" : \"claude\"") || json.contains("\"kind\":\"claude\""))
                  && !json.contains("\"_0\""),
                  "model=\(decoded.action.model ?? "nil") effort=\(decoded.action.effort ?? "nil")")
        } else {
            check("store.roundTrip", false, "encodage ou décodage impossible")
        }

        // ── 2. Fichier v1 (Superset) et fichier illisible ────────────────────────
        SchedulePaths.ensureDirectories()
        try? Data(legacyFile.utf8).write(to: SchedulePaths.schedulesFile)
        check("store.legacy", ScheduleStore.readDisk() == .legacy(version: 1)
              && ScheduleStore.loadFromDisk().isEmpty, "\(ScheduleStore.readDisk())")

        // `reload()` sur un v1 : c'est la suppression décidée des planifications Superset.
        store.reload()
        store.stopWatchingRuns()          // pas de runloop en CLI : on n'arme rien
        let purged = (try? String(contentsOf: SchedulePaths.schedulesFile)) ?? ""
        check("store.legacyPurged", store.schedules.isEmpty
              && ScheduleStore.readDisk() == .current([])
              && purged.contains("\"version\" : 2"),
              purged.replacingOccurrences(of: "\n", with: " "))

        try? Data("{".utf8).write(to: SchedulePaths.schedulesFile)
        check("store.unreadable", ScheduleStore.readDisk() == .unreadable)
        store.reload()
        store.stopWatchingRuns()
        check("store.unreadableUntouched",
              (try? String(contentsOf: SchedulePaths.schedulesFile)) == "{"
              && store.lastError != nil, store.lastError ?? "aucune erreur posée")
        // Même une écriture explicite ne doit pas écraser un fichier qu'on n'a pas su lire.
        store.upsert(complet)
        check("store.unreadableNoWrite",
              (try? String(contentsOf: SchedulePaths.schedulesFile)) == "{")
        try? fm.removeItem(at: SchedulePaths.schedulesFile)
        store.reload()
        store.stopWatchingRuns()

        // ── 3. Validation par volet ──────────────────────────────────────────────
        out.append("")
        out.append("— validation —")
        let valide = Schedule(
            name: "Valide", folderPath: work.path,
            action: .claude(prompt: "Un prompt assez long pour passer.", model: nil,
                            effort: nil, settingsPath: nil),
            recurrence: .daily(hour: 9, minute: 0))
        check("store.validationBase", valide.validationReport(existingNames: []).isValid,
              valide.validate(existingNames: []).joined(separator: " ; "))

        typealias Volet = WritableKeyPath<Schedule.ValidationReport, [String]>
        func expectOne(_ label: String, _ volet: Volet, _ mutate: (inout Schedule) -> Void) {
            var candidate = valide
            mutate(&candidate)
            let report = candidate.validationReport(existingNames: [])
            let all: [Volet] = [\.identity, \.folder, \.claude, \.prompt, \.recurrence]
            let ok = report[keyPath: volet].count == 1
                && all.filter { $0 != volet }.allSatisfy { report[keyPath: $0].isEmpty }
            check("store.validation.\(label)", ok, report.all.joined(separator: " ; "))
        }
        expectOne("nomVide", \.identity) { $0.name = "  " }
        expectOne("dossierRelatif", \.folder) { $0.folderPath = "relatif/dossier" }
        expectOne("dossierInexistant", \.folder) { $0.folderPath = work.path + "/absent" }
        expectOne("prompt19", \.prompt) {
            $0.action = .claude(prompt: String(repeating: "p", count: 19), model: nil,
                                effort: nil, settingsPath: nil)
        }
        expectOne("délai0", \.claude) { $0.timeoutMinutes = 0 }
        expectOne("délai241", \.claude) { $0.timeoutMinutes = 241 }
        expectOne("settingsAbsent", \.claude) {
            $0.action = .claude(prompt: "Un prompt assez long pour passer.", model: nil,
                                effort: nil, settingsPath: work.path + "/absent.json")
        }
        expectOne("mcpVide", \.claude) { $0.requiredMCPServers = ["  "] }

        // ── 4. CRUD ──────────────────────────────────────────────────────────────
        out.append("")
        out.append("— création, désactivation, suppression —")
        let hebdo = Schedule(
            name: "Audit hebdomadaire", folderPath: work.path,
            action: .claude(prompt: "Audite les dépendances et résume les CVE ouvertes.",
                            model: nil, effort: "xhigh", settingsPath: nil),
            recurrence: .weekly(weekdays: [1, 4], hour: 9, minute: 15))
        store.upsert(complet)
        store.upsert(hebdo)
        store.reload()
        store.stopWatchingRuns()
        check("2 planifications relues", store.schedules.count == 2, "\(store.schedules.count)")
        check("tri alphabétique appliqué", store.schedules.first?.name == "Audit hebdomadaire",
              store.schedules.map(\.name).joined(separator: " | "))
        check("relue à l'identique (hors updatedAt)",
              store.schedules.first { $0.id == complet.id }.map {
                  $0.action == complet.action && $0.preScript == complet.preScript
                      && $0.requiredMCPServers == complet.requiredMCPServers
                      && $0.timeoutMinutes == complet.timeoutMinutes
              } == true)

        store.setEnabled(false, id: hebdo.id)
        store.reload()
        store.stopWatchingRuns()
        check("« Audit hebdomadaire » désactivée",
              store.schedules.first { $0.id == hebdo.id }?.enabled == false)

        store.remove(id: hebdo.id)
        store.reload()
        store.stopWatchingRuns()
        check("1 planification restante, la bonne",
              store.schedules.map(\.id) == [complet.id], "\(store.schedules.count)")

        // ── 5. JSONL : pliage ────────────────────────────────────────────────────
        out.append("")
        out.append("— historique (JSONL append-only) —")

        // Run A : complet, `completed`, avec sa conversation.
        let runA = UUID()
        let sessionA = UUID().uuidString.lowercased()
        let logA = RunLog(runID: runA, scheduleID: complet.id, trigger: "launchd")
        logA.start()
        logA.note("préscript : OK")
        logA.finish(status: .completed, message: "session terminée", sessionID: sessionA)

        // Run B : `start` SANS `end`, pid mort ⇒ doit se plier en `interrupted`.
        let runB = UUID()
        RunLog.append(RunLine.start(runID: runB, scheduleID: complet.id,
                                    trigger: "launchd", pid: deadPID, at: Date()))

        let lines = RunLog.loadLines()
        check("3 lignes écrites (start+end pour A, start seul pour B)",
              lines.count == 3, "\(lines.count)")

        let records = RunLog.recent(scheduleID: complet.id, limit: 10)
        let a = records.first { $0.id == runA }
        let b = records.first { $0.id == runB }
        check("store.fold.completed", a?.status == .completed && a?.sessionID == sessionA
              && a?.duration != nil && a?.logPath != nil,
              a.map { "\($0.status.rawValue) · \($0.message) · \($0.sessionID ?? "nil")" } ?? "absent")
        check("store.fold.interrupted", b?.status == .interrupted && b?.endedAt == nil
              && b?.sessionID == nil,
              b.map { "\($0.status.rawValue) · \($0.message)" } ?? "absent")
        check("store.fold.running", RunRecord.fold(
            [RunLine.start(runID: runB, scheduleID: complet.id, trigger: "manual",
                           pid: deadPID, at: Date())],
            isAlive: { _ in true }).first?.status == .running)
        check("tri du plus récent au plus ancien",
              records.first?.startedAt ?? .distantPast >= records.last?.startedAt ?? .distantFuture)
        check("le JSONL n'a pas été réécrit par le pliage",
              RunLog.loadLines().count == 3, "\(RunLog.loadLines().count)")

        check("completed ne déclenche pas de bannière", !RunStatus.completed.deservesNotification)
        check("failed, skipped et timedOut en déclenchent une",
              RunStatus.failed.deservesNotification && RunStatus.skipped.deservesNotification
              && RunStatus.timedOut.deservesNotification)

        // ── 6. Message plafonné ──────────────────────────────────────────────────
        out.append("")
        out.append("— plafond du champ `message` —")
        let runC = UUID()
        RunLog(runID: runC, scheduleID: complet.id, trigger: "manual")
            .finish(status: .failed, message: String(repeating: "x", count: 2_000), sessionID: nil)
        let cLine = RunLog.loadLines().first { $0.runID == runC }
        check("message tronqué à \(RunLine.maxMessageLength) caractères",
              cLine?.message?.count == RunLine.maxMessageLength,
              "\(cLine?.message?.count ?? -1)")

        // ── 7. Compaction EN PLACE ───────────────────────────────────────────────
        // L'assertion qui compte est **l'inode inchangé** — un `rename` ferait écrire un
        // appender déjà ouvert dans un fichier devenu invisible.
        out.append("")
        out.append("— compaction en place —")

        let runsURL = SchedulePaths.runsFile
        func inode(_ url: URL) -> UInt64? {
            (try? fm.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
        }
        func fileSize(_ url: URL) -> Int {
            ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }

        let padding = String(repeating: "y", count: RunLine.maxMessageLength)
        var generated = 0
        while fileSize(runsURL) <= RunLog.compactionThresholdBytes {
            RunLog.append(RunLine.end(
                runID: UUID(), scheduleID: complet.id, at: Date(),
                status: .completed, message: padding, sessionID: nil, logPath: nil))
            generated += 1
        }

        let inodeBefore = inode(runsURL)
        let sizeBefore = fileSize(runsURL)
        out.append("  \(generated) lignes générées · \(sizeBefore) octets")
        RunLog.compactIfNeeded()

        let linesAfter = RunLog.loadLines().count
        check("compacté à \(RunLog.compactionKeepLines) lignes",
              linesAfter == RunLog.compactionKeepLines, "\(linesAfter)")
        check("le fichier a bien rétréci", fileSize(runsURL) < sizeBefore,
              "\(sizeBefore) → \(fileSize(runsURL))")
        check("⭐ INODE INCHANGÉ (réécriture en place, pas de rename)",
              inodeBefore != nil && inode(runsURL) == inodeBefore,
              "\(inodeBefore.map(String.init) ?? "?") → \(inode(runsURL).map(String.init) ?? "?")")
        let inodeStable = inode(runsURL)
        RunLog.compactIfNeeded()
        check("second appel sous le seuil = no-op",
              RunLog.loadLines().count == linesAfter && inode(runsURL) == inodeStable)

        // ── 8. Effets de bord ────────────────────────────────────────────────────
        out.append("")
        out.append("— effets de bord —")
        let realStoreExistsAfter = fm.fileExists(atPath: realStore.path)
        check("le dossier scheduler RÉEL n'a pas été créé par le probe",
              realStoreExistsAfter == realStoreExistedBefore,
              realStoreExistsAfter ? "présent (déjà avant : \(realStoreExistedBefore))" : "absent")

        let drift = realPlists().symmetricDifference(realPlistsBefore).sorted()
        check("le VRAI ~/Library/LaunchAgents est INCHANGÉ", drift.isEmpty,
              drift.isEmpty
                  ? "\(realPlistsBefore.count) plist(s) Potof avant comme après"
                  : "écart : \(drift.joined(separator: ", "))")

        let dryPlists = (try? fm.contentsOfDirectory(
            atPath: SchedulePaths.launchAgentsDirectory.path))?.sorted() ?? []
        out.append("  plists écrits dans le dossier jetable : \(dryPlists.count)")
        for name in dryPlists { out.append("    \(name)") }

        // ── Nettoyage ────────────────────────────────────────────────────────────
        try? fm.removeItem(at: root)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
