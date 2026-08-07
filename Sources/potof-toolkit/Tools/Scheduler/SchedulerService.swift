import Foundation
import Combine

/// Installation / retrait / audit des jobs launchd — **lot L2**.
///
/// ## `bootstrap` / `bootout`, pas `load` / `unload`
/// Ces derniers sont des shims dépréciés au comportement subtilement différent. Domaine
/// `gui/<uid>` avec `uid = getuid()`, `launchctl` invoqué par chemin absolu.
/// ```
/// install : (1) createDirectory(logs)          ← sinon le job échoue sans message exploitable
///           (2) écriture atomique du .plist
///           (3) launchctl bootout   gui/<uid>/<label>   # tolérer exit 3 (ESRCH) et 113
///           (4) launchctl enable    gui/<uid>/<label>   # un `disable` PERSISTE et survit à bootstrap
///           (5) launchctl bootstrap gui/<uid> <plistPath>
/// remove  : (1) launchctl bootout gui/<uid>/<label>     # tolérer exit 3
///           (2) suppression du .plist
/// status  : launchctl print gui/<uid>/<label>           # exit 0 = chargé
/// ```
/// Trois choses à savoir :
/// - **Réécrire le fichier ne recharge rien.** Le job chargé garde en mémoire l'ancienne
///   définition ⇒ `bootout` + `bootstrap` obligatoires à **chaque** modification.
/// - `bootstrap` sur un job déjà chargé rend `Bootstrap failed: 37` / `5` — d'où le
///   `bootout` systématique en amont, dont l'échec est **toléré**.
/// - L'étape `enable` n'est pas décorative : `launchctl disable` écrit dans une base **par
///   utilisateur qui survit à `bootout`/`bootstrap`**. Sans elle, un job désactivé une
///   fois resterait muet pour toujours, plist parfaitement valide à l'appui.
///
/// ## Règle d'écriture dans `~/Library/LaunchAgents` — NON NÉGOCIABLE
/// Ce dossier permet d'exécuter du code arbitraire à l'ouverture de session. On ne
/// supprime/écrase un fichier **que si** son nom est
/// `com.potof.toolkit.schedule.<uuid>.plist` **ET** que son `ProgramArguments[0]` se
/// termine par `/potof-toolkit`. **Jamais de suppression par glob.** Un bug de préfixe qui
/// effacerait le plist d'un autre éditeur serait irréparable côté utilisateur.
/// Corollaire assumé : un fichier portant notre nom mais **illisible** (plist corrompu)
/// n'est pas « le nôtre » — on refuse de l'écraser et on dit lequel, à la main.
///
/// ⚠️ `install` / `remove` **court-circuitent `launchctl` quand `SchedulePaths.isDryRun`**
/// — sans quoi un probe installerait de vrais jobs.
///
/// ⚠️ **Aucune méthode de ce fichier ne déclenche un run.** Voir le commentaire à
/// l'emplacement de l'ancien `kickstart`, plus bas : c'est délibéré.
final class SchedulerService: ObservableObject {

    static let shared = SchedulerService()
    private init() {}

    /// Préfixe qui autorise la suppression (voir la règle ci-dessus).
    static let labelPrefix = "com.potof.toolkit.schedule."
    /// Suffixe attendu de `ProgramArguments[0]`, seconde condition de la même règle.
    static let executableSuffix = "/potof-toolkit"

    /// `launchctl` par **chemin absolu** : sous launchd comme depuis le Finder, le PATH
    /// n'est pas celui d'un shell de login. Même règle que `Git.executablePath`.
    private static let launchctlPath = "/bin/launchctl"

    /// `bootout` sur un job non chargé : `3` = ESRCH (« No such process »), `113` =
    /// « Could not find specified service ». Les deux sont le cas NOMINAL de la première
    /// installation — les traiter en échec rendrait `install` impossible.
    private static let tolerableBootoutCodes: Set<Int32> = [0, 3, 113]

    /// Dernier résultat d'`auditOnLaunch()`, pour le bandeau « … · Réparer ». Publié sur
    /// le thread principal ; vide tant que l'audit n'a pas tourné.
    @Published private(set) var auditIssues: [AuditIssue] = []

    // MARK: - Cibles launchd

    private var domainTarget: String { "gui/\(getuid())" }
    private func serviceTarget(_ schedule: Schedule) -> String {
        "\(domainTarget)/\(schedule.launchAgentLabel)"
    }

    // MARK: - Installation

    func install(_ schedule: Schedule) -> LaunchAgentResult {
        // En `swift run`, le binaire vit dans `.build/debug/` — chemin éphémère effacé par
        // `swift package clean`. Un plist pointant là serait mort au premier nettoyage,
        // sans le moindre signal. En dry-run on continue : rien ne sort du dossier jetable.
        guard SchedulePaths.canInstallLaunchAgents || SchedulePaths.isDryRun else {
            return LaunchAgentResult(
                ok: false,
                message: "Les planifications ne s'installent que depuis l'app bundlée. "
                       + "En dev, utilisez « Lancer maintenant ».")
        }

        let plistURL = SchedulePaths.launchAgentPlistURL(for: schedule)
        let fm = FileManager.default

        // (1) Les dossiers d'abord. `StandardOutPath` pointant dans un dossier absent
        //     fait échouer le job **sans message exploitable** : c'est la panne la plus
        //     coûteuse à diagnostiquer de tout le chantier.
        do {
            try fm.createDirectory(at: SchedulePaths.launchdLogsDirectory,
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: SchedulePaths.launchAgentsDirectory,
                                   withIntermediateDirectories: true)
        } catch {
            return LaunchAgentResult(
                ok: false,
                message: "Impossible de créer les dossiers du job : \(error.localizedDescription)")
        }

        // (2) Écriture atomique — mais jamais par-dessus un fichier qui n'est pas à nous.
        switch ownership(ofPlistAt: plistURL) {
        case .foreign(let why):
            return LaunchAgentResult(
                ok: false,
                message: "Refus d'écraser \(plistURL.path) : \(why). "
                       + "Supprimez ce fichier à la main si vous savez ce qu'il est.")
        case .absent, .mine:
            break
        }

        let executablePath = SchedulePaths.hostExecutableURL.path
        do {
            let data = try LaunchAgentPlist.data(for: schedule, executablePath: executablePath)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return LaunchAgentResult(
                ok: false,
                message: "Impossible d'écrire \(plistURL.lastPathComponent) : \(error.localizedDescription)")
        }

        // (3-5) launchctl — court-circuité en dry-run.
        guard !SchedulePaths.isDryRun else {
            return LaunchAgentResult(
                ok: true,
                message: "dry-run : \(plistURL.lastPathComponent) écrit, launchctl NON invoqué.")
        }

        var notes: [String] = []

        // (3) bootout : échec toléré (première installation ⇒ ESRCH).
        let bootout = runLaunchctl(["bootout", serviceTarget(schedule)])
        if !Self.tolerableBootoutCodes.contains(bootout.code) {
            notes.append("bootout a rendu \(bootout.code) (\(bootout.output))")
        }

        // (4) enable : `launchctl disable` écrit dans une base par utilisateur qui SURVIT
        //     à bootout/bootstrap. Sans cette étape, un job désactivé une fois resterait
        //     muet pour toujours, plist parfaitement valide à l'appui.
        let enable = runLaunchctl(["enable", serviceTarget(schedule)])
        if enable.code != 0 {
            notes.append("enable a rendu \(enable.code) (\(enable.output))")
        }

        // (5) bootstrap : c'est le seul échec qui compte.
        let bootstrap = runLaunchctl(["bootstrap", domainTarget, plistURL.path])
        guard bootstrap.code == 0 else {
            return LaunchAgentResult(
                ok: false,
                message: "bootstrap a échoué (\(bootstrap.code)) : "
                       + (bootstrap.output.isEmpty ? "aucun message" : bootstrap.output))
        }

        let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: " ; ")
        return LaunchAgentResult(ok: true, message: "Job \(schedule.launchAgentLabel) chargé.\(suffix)")
    }

    func remove(_ schedule: Schedule) -> LaunchAgentResult {
        let plistURL = SchedulePaths.launchAgentPlistURL(for: schedule)
        var notes: [String] = []

        if !SchedulePaths.isDryRun {
            let bootout = runLaunchctl(["bootout", serviceTarget(schedule)])
            if !Self.tolerableBootoutCodes.contains(bootout.code) {
                notes.append("bootout a rendu \(bootout.code) (\(bootout.output))")
            }
        } else {
            notes.append("dry-run : launchctl NON invoqué")
        }

        switch ownership(ofPlistAt: plistURL) {
        case .absent:
            notes.append("aucun plist à supprimer")
        case .foreign(let why):
            return LaunchAgentResult(
                ok: false,
                message: "Refus de supprimer \(plistURL.path) : \(why).")
        case .mine:
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                return LaunchAgentResult(
                    ok: false,
                    message: "Impossible de supprimer \(plistURL.lastPathComponent) : "
                           + error.localizedDescription)
            }
        }

        let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: " ; ")
        return LaunchAgentResult(ok: true, message: "Job \(schedule.launchAgentLabel) retiré.\(suffix)")
    }

    /// Purge un plist **orphelin** — un fichier à notre nom sans `Schedule` correspondant,
    /// tel que remonté par `audit()` en `.orphanPlist(<nom de fichier>)`.
    ///
    /// Existe parce que `remove(_:)` exige un `Schedule` qu'un orphelin n'a **pas** : sans
    /// cette porte, l'interface devrait fabriquer un `Schedule` factice à partir de l'UUID
    /// extrait du nom de fichier — exactement le genre de contorsion qui finit par
    /// contourner la règle des deux conditions. Ici la règle est appliquée telle quelle,
    /// par le même `ownership(ofPlistAt:)` que partout ailleurs.
    func removeOrphan(plistNamed fileName: String) -> LaunchAgentResult {
        // Le nom vient d'`audit()`, mais on ne fait aucune confiance à son origine :
        // un composant de chemin y transformerait la suppression en arme.
        guard !fileName.contains("/"), fileName == (fileName as NSString).lastPathComponent else {
            return LaunchAgentResult(ok: false, message: "Nom de plist invalide : « \(fileName) ».")
        }
        let plistURL = SchedulePaths.launchAgentsDirectory
            .appendingPathComponent(fileName, isDirectory: false)

        switch ownership(ofPlistAt: plistURL) {
        case .absent:
            return LaunchAgentResult(ok: true, message: "\(fileName) n'existe plus.")
        case .foreign(let why):
            return LaunchAgentResult(
                ok: false,
                message: "Refus de supprimer \(plistURL.path) : \(why). "
                       + "Supprimez ce fichier à la main si vous savez ce qu'il est.")
        case .mine:
            break
        }

        var notes: [String] = []
        let label = String(fileName.dropLast(".plist".count))
        if !SchedulePaths.isDryRun {
            let bootout = runLaunchctl(["bootout", "\(domainTarget)/\(label)"])
            if !Self.tolerableBootoutCodes.contains(bootout.code) {
                notes.append("bootout a rendu \(bootout.code) (\(bootout.output))")
            }
        } else {
            notes.append("dry-run : launchctl NON invoqué")
        }

        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            return LaunchAgentResult(
                ok: false,
                message: "Impossible de supprimer \(fileName) : \(error.localizedDescription)")
        }
        let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: " ; ")
        return LaunchAgentResult(ok: true, message: "Orphelin \(fileName) purgé.\(suffix)")
    }

    /// `launchctl print gui/<uid>/<label>` : exit 0 = chargé.
    ///
    /// En dry-run, `launchctl` n'est jamais invoqué — on rend alors la **présence du
    /// plist** dans le dossier jetable. C'est la seule doublure honnête possible, et elle
    /// garde `audit()` cohérent à l'intérieur d'un probe.
    func isLoaded(_ schedule: Schedule) -> Bool {
        guard !SchedulePaths.isDryRun else {
            return FileManager.default.fileExists(
                atPath: SchedulePaths.launchAgentPlistURL(for: schedule).path)
        }
        return runLaunchctl(["print", serviceTarget(schedule)], discardingOutput: true).code == 0
    }

    // ⚠️ **PAS de `kickstart` ici, et surtout ne pas le réintroduire.**
    //
    // `launchctl kickstart -k gui/<uid>/<label>` exécute le `ProgramArguments` du plist,
    // c'est-à-dire `--run-schedule <uuid>` SANS `--dry-run` : un run **complet et réel**,
    // qui crée un workspace, fait un `reset --hard` sur le worktree et lance un agent
    // payant. On ne peut pas en faire une simulation — le plist fige son argv, et c'est
    // voulu (aucun texte utilisateur dans `~/Library/LaunchAgents`).
    //
    // Il a existé, derrière un bouton « Tester le déclencheur » présenté comme un
    // diagnostic. Il a lancé deux agents réels en trois clics avant qu'on s'en aperçoive.
    // Même raisonnement que la suppression de `confirmEditInTerminal` dans le pont IDE :
    // une affordance qui ment sur son effet ne se corrige pas par un meilleur libellé, on
    // la retire. La simulation vit maintenant dans `ScheduleRunner.executeReporting(…,
    // dryRun: true)`, en-process et sans le moindre effet de bord ; `isLoaded(_:)`
    // ci-dessus couvre la seule question que le kickstart répondait vraiment.

    // MARK: - Audit

    /// Compare l'état de `~/Library/LaunchAgents` à ce que la GUI croit avoir installé.
    ///
    /// **Rend systématiquement `[]` en dev** (`canInstallLaunchAgents == false`) : le
    /// binaire courant est alors `.build/debug/potof-toolkit`, donc *toutes* les
    /// planifications créées par l'app bundlée seraient signalées en `pathMismatch` — un
    /// bandeau intégralement faux, et une réparation de toute façon interdite (`install`
    /// refuse hors bundle).
    func audit(against schedules: [Schedule]) -> [AuditIssue] {
        guard SchedulePaths.canInstallLaunchAgents || SchedulePaths.isDryRun else { return [] }

        var issues: [AuditIssue] = []
        let expectedExecutable = SchedulePaths.hostExecutableURL.path
        var known = Set<String>()

        for schedule in schedules {
            let plistURL = SchedulePaths.launchAgentPlistURL(for: schedule)
            known.insert(plistURL.lastPathComponent)

            guard let dict = readPlist(at: plistURL) else {
                // Plist absent ou illisible : pour une planification activée, c'est
                // exactement « le job n'est pas chargé ».
                if schedule.enabled { issues.append(.notLoaded(schedule.id)) }
                continue
            }
            if let arguments = dict["ProgramArguments"] as? [String],
               let program = arguments.first,
               program != expectedExecutable {
                issues.append(.pathMismatch(schedule.id, program))
            }
            if schedule.enabled && !isLoaded(schedule) {
                issues.append(.notLoaded(schedule.id))
            }
        }

        // Orphelins : nos plists sans `Schedule` correspondant. On ne réclame QUE les
        // fichiers qui passent les deux conditions de propriété — un fichier au bon nom
        // mais pointant ailleurs n'est pas à nous et ne doit jamais être proposé à la purge.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: SchedulePaths.launchAgentsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !known.contains(url.lastPathComponent) {
            if case .mine = ownership(ofPlistAt: url) {
                issues.append(.orphanPlist(url.lastPathComponent))
            }
        }
        return issues
    }

    /// Réinstalle les planifications activées (ce qui réécrit `ProgramArguments[0]` avec
    /// le chemin courant du binaire, puis `bootout` + `bootstrap`) et retire les autres.
    ///
    /// Ne purge **pas** les orphelins : `audit()` les liste, leur suppression reste une
    /// action explicite de l'utilisateur (§6.4 « proposition de purge »).
    func repairAll(_ schedules: [Schedule]) -> [LaunchAgentResult] {
        schedules.map { $0.enabled ? install($0) : remove($0) }
    }

    /// Appelé par `AppDelegate` au démarrage. **Ne doit jamais lever ni bloquer** : c'est
    /// du diagnostic d'arrière-plan, pas un chemin critique de lancement de l'app.
    func auditOnLaunch() {
        guard SchedulePaths.canInstallLaunchAgents else { return }
        DispatchQueue.global(qos: .utility).async {
            // `loadFromDisk` est implémentée par le socle et ne dépend d'aucun lot :
            // l'audit au démarrage ne réveille donc aucun singleton de la liste noire.
            let issues = self.audit(against: ScheduleStore.loadFromDisk())
            DispatchQueue.main.async { self.auditIssues = issues }
        }
    }

    // MARK: - Propriété d'un fichier de LaunchAgents

    /// Résultat de la règle non négociable. `.foreign` porte **pourquoi**, parce que le
    /// message est la seule issue laissée à l'utilisateur.
    enum PlistOwnership {
        case absent
        case mine
        case foreign(String)
    }

    /// Les DEUX conditions sont requises : nom `com.potof.toolkit.schedule.<uuid>.plist`
    /// **ET** `ProgramArguments[0]` terminant par `/potof-toolkit`.
    func ownership(ofPlistAt url: URL) -> PlistOwnership {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }

        let fileName = url.lastPathComponent
        guard fileName.hasSuffix(".plist") else { return .foreign("ce n'est pas un .plist") }
        let label = String(fileName.dropLast(".plist".count))
        guard label.hasPrefix(Self.labelPrefix) else {
            return .foreign("le nom ne commence pas par « \(Self.labelPrefix) »")
        }
        guard UUID(uuidString: String(label.dropFirst(Self.labelPrefix.count))) != nil else {
            return .foreign("le suffixe du nom n'est pas un UUID")
        }
        guard let dict = readPlist(at: url) else {
            return .foreign("plist illisible — impossible de vérifier ProgramArguments")
        }
        guard let program = (dict["ProgramArguments"] as? [String])?.first else {
            return .foreign("aucun ProgramArguments exploitable")
        }
        guard program.hasSuffix(Self.executableSuffix) else {
            return .foreign("ProgramArguments[0] ne se termine pas par « \(Self.executableSuffix) » "
                          + "(\(program))")
        }
        return .mine
    }

    private func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: - launchctl

    private func runLaunchctl(_ arguments: [String],
                              discardingOutput: Bool = false) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.launchctlPath)
        process.arguments = arguments

        // `launchctl print` crache des centaines de lignes : quand seul le code de sortie
        // compte, on ne les lit pas.
        let outPipe = Pipe()
        let errPipe = Pipe()
        if discardingOutput {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        } else {
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        do {
            try process.run()
        } catch {
            return (-1, "impossible de lancer launchctl : \(error.localizedDescription)")
        }

        var text = ""
        if !discardingOutput {
            // Lecture AVANT waitUntilExit : un pipe plein bloquerait le process fils.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            text = ((String(data: errData, encoding: .utf8) ?? "")
                    + (String(data: outData, encoding: .utf8) ?? ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    // MARK: - Auto-test (appelé par `LaunchAgentPlist.probe()`)

    /// Exerce `install` / `isLoaded` / `audit` / `repairAll` / `remove`
    /// **entièrement dans un dossier jetable** : `SchedulePaths.overrideRoot` est posé le
    /// temps du probe, ce qui détourne `launchAgentsDirectory` **et** met `isDryRun` à
    /// vrai, donc `launchctl` n'est jamais invoqué. La racine est restaurée à la sortie.
    static func dryRunProbe(_ schedules: [Schedule]) -> (report: String, failures: Int) {
        var out: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            if !ok { failures += 1 }
            out.append("  [\(ok ? "OK  " : "ÉCHEC")] \(label)")
        }

        let fm = FileManager.default
        let root: URL = {
            if let custom = ProcessInfo.processInfo
                .environment[LaunchAgentPlist.probeRootEnvironmentKey], !custom.isEmpty {
                return URL(fileURLWithPath: custom)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("potof-sched-l2-probe", isDirectory: true)
        }()

        let realLaunchAgents = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        let previousRoot = SchedulePaths.overrideRoot
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = previousRoot }

        // Repartir d'un dossier propre : le probe doit être rejouable.
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let service = SchedulerService.shared
        let agentsDir = SchedulePaths.launchAgentsDirectory

        out.append("  overrideRoot        : \(root.path)")
        out.append("  launchAgentsDirectory : \(agentsDir.path)")
        out.append("  (réel, jamais touché) : \(realLaunchAgents.path)")
        out.append("  isDryRun            : \(SchedulePaths.isDryRun)")
        check(SchedulePaths.isDryRun, "isDryRun est vrai ⇒ launchctl court-circuité")
        check(!agentsDir.path.hasPrefix(realLaunchAgents.path),
              "launchAgentsDirectory est détourné hors de ~/Library/LaunchAgents")
        check(SchedulePaths.launchdLogsDirectory.path.hasPrefix(root.path),
              "launchdLogsDirectory est détourné hors de ~/Library/Logs/PotofToolkit")

        // ── install ──────────────────────────────────────────────────────────────
        out.append("")
        out.append("  — install (les 4 cadences) —")
        for schedule in schedules {
            let result = service.install(schedule)
            let url = SchedulePaths.launchAgentPlistURL(for: schedule)
            check(result.ok && fm.fileExists(atPath: url.path),
                  "\(schedule.name) → \(url.lastPathComponent) — \(result.message)")
        }
        check(fm.fileExists(atPath: SchedulePaths.launchdLogsDirectory.path),
              "le dossier de logs launchd est créé AVANT le bootstrap")

        // ── isLoaded + audit propre ──────────────────────────────────────────────
        out.append("")
        out.append("  — isLoaded / audit —")
        check(schedules.allSatisfy { service.isLoaded($0) },
              "isLoaded (doublure dry-run = présence du plist) est vrai pour les 4")
        let clean = service.audit(against: schedules)
        check(clean.isEmpty, "audit après installation : aucune anomalie (obtenu : \(clean))")

        // ── pathMismatch + repairAll ─────────────────────────────────────────────
        out.append("")
        out.append("  — détection d'un déplacement de l'app —")
        let moved = schedules[1]
        let movedURL = SchedulePaths.launchAgentPlistURL(for: moved)
        let stalePath = "/Applications/Ancien Emplacement.app/Contents/MacOS/potof-toolkit"
        if let staleData = try? LaunchAgentPlist.data(for: moved, executablePath: stalePath) {
            try? staleData.write(to: movedURL, options: .atomic)
        }
        let mismatches = service.audit(against: schedules)
        check(mismatches.contains(.pathMismatch(moved.id, stalePath)),
              "audit signale pathMismatch(\(moved.name), \(stalePath))")
        let repairs = service.repairAll(schedules)
        check(repairs.allSatisfy { $0.ok }, "repairAll : \(repairs.filter { $0.ok }.count)/\(repairs.count) OK")
        check(service.audit(against: schedules).isEmpty, "audit après réparation : plus d'anomalie")

        // ── la règle non négociable ──────────────────────────────────────────────
        out.append("")
        out.append("  — refus d'écraser un fichier qui n'est pas à nous —")
        let intruderID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let intruder = Schedule(
            id: intruderID, name: "Intrus", action: schedules[0].action,
            recurrence: schedules[0].recurrence, target: schedules[0].target)
        let intruderURL = SchedulePaths.launchAgentPlistURL(for: intruder)
        let foreignPlist: [String: Any] = [
            "Label": intruder.launchAgentLabel,
            "ProgramArguments": ["/usr/bin/true"],
            "RunAtLoad": false
        ]
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: foreignPlist, format: .xml, options: 0) {
            try? data.write(to: intruderURL, options: .atomic)
        }
        let refusedInstall = service.install(intruder)
        check(!refusedInstall.ok, "install refuse d'écraser : \(refusedInstall.message)")
        let refusedRemove = service.remove(intruder)
        check(!refusedRemove.ok, "remove refuse de supprimer : \(refusedRemove.message)")
        let survivor = (try? Data(contentsOf: intruderURL)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil))
                as? [String: Any]
        }
        check((survivor?["ProgramArguments"] as? [String])?.first == "/usr/bin/true",
              "…et le fichier étranger est INTACT")
        check(!service.audit(against: schedules).contains(.orphanPlist(intruderURL.lastPathComponent)),
              "…et il n'est pas proposé à la purge (il ne passe pas les deux conditions)")
        try? fm.removeItem(at: intruderURL)

        // ── orphelin réel ────────────────────────────────────────────────────────
        out.append("")
        out.append("  — orphelin (plist à nous, sans planification) —")
        let orphan = Schedule(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            name: "Orphelin", action: schedules[0].action,
            recurrence: schedules[0].recurrence, target: schedules[0].target)
        _ = service.install(orphan)
        let orphanName = SchedulePaths.launchAgentPlistURL(for: orphan).lastPathComponent
        check(service.audit(against: schedules).contains(.orphanPlist(orphanName)),
              "audit signale orphanPlist(\(orphanName))")
        let orphanRemoval = service.remove(orphan)
        check(orphanRemoval.ok
              && !fm.fileExists(atPath: SchedulePaths.launchAgentPlistURL(for: orphan).path),
              "remove supprime notre propre plist — \(orphanRemoval.message)")

        // ── remove / réinstallation ──────────────────────────────────────────────
        out.append("")
        out.append("  — remove —")
        let removed = service.remove(schedules[3])
        check(removed.ok
              && !fm.fileExists(atPath: SchedulePaths.launchAgentPlistURL(for: schedules[3]).path),
              "remove(\(schedules[3].name)) — \(removed.message)")
        check(service.install(schedules[3]).ok, "réinstallation de \(schedules[3].name) pour le lint")

        // ── état final ───────────────────────────────────────────────────────────
        out.append("")
        out.append("  — état final du dossier jetable —")
        let finalFiles = ((try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? []).sorted()
        for file in finalFiles { out.append("    \(agentsDir.path)/\(file)") }
        check(finalFiles.count == schedules.count,
              "\(finalFiles.count) plist(s) dans le dossier jetable, pour \(schedules.count) cadence(s)")
        out.append("  → `plutil -lint \(agentsDir.path)/*.plist` doit passer sur ces fichiers.")

        return (out.joined(separator: "\n"), failures)
    }
}

struct LaunchAgentResult {
    let ok: Bool
    let message: String
}

enum AuditIssue: Hashable {
    /// Le `ProgramArguments[0]` du plist ne correspond plus au binaire courant : l'app a
    /// été déplacée, launchd tire un binaire absent et **échoue en silence**.
    case pathMismatch(UUID, String)
    /// Un plist `com.potof.toolkit.schedule.*` sans `Schedule` correspondant.
    case orphanPlist(String)
    /// Planification activée dont le job n'est pas chargé.
    case notLoaded(UUID)
}
