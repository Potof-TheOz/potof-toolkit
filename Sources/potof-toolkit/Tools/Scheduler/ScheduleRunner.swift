import Foundation   // ⚠️ JAMAIS AppKit, JAMAIS SwiftUI — garantie STRUCTURELLE : avec ce
                    //    seul import, `NSApp` devient une erreur de compilation.

/// Ce dont le runner a besoin du poste. `live` en production ; les probes substituent un
/// shell, un faux `claude` et des délais courts.
struct RunnerHost {
    var shell: String
    /// `"claude"` en vrai (résolu par le PATH du shell de login) ; un faux script en probe.
    var claudeCommand: String
    var preScriptTimeout: TimeInterval
    var mcpListTimeout: TimeInterval
    /// Remplace `timeoutMinutes × 60` (probe seulement).
    var sessionTimeoutOverride: TimeInterval?

    static var live: RunnerHost {
        RunnerHost(shell: ClaudeInvocation.shell(from: ProcessInfo.processInfo.environment),
                   claudeCommand: "claude",
                   preScriptTimeout: 600,
                   mcpListTimeout: 90,
                   sessionTimeoutOverride: nil)
    }
}

/// Mode **headless** du binaire : `potof-toolkit --run-schedule <uuid> [--dry-run]`.
///
/// Vit **avant** `NSApplication` (cf. `main.swift`) et ne revient jamais. Même contrat
/// que `IDESelfTest.run(arguments:flagIndex:)`.
///
/// ## La séquence
/// Dossier → préscript (dans un PTY, attendu jusqu'au bout) → `claude mcp list` si des MCP
/// sont requis → settings du run (ceux de la planification + un hook `Stop`) → session
/// `claude` interactive dans un PTY 120×40 que le runner possède, enregistrée dans
/// `logs/<runID>.tty`, fermée par `/exit` dès que le hook `Stop` a posé son marqueur.
/// Les messages de chaque issue sont vérifiés au mot près par `--sched-selftest run`.
///
/// ## Liste noire — ce que ce mode ne doit JAMAIS toucher
/// Les singletons du dépôt sont tous lazy : aucun ne s'initialise au démarrage du
/// process. C'est ce qui rend ce mode sûr, à condition de ne pas les réveiller :
///
/// - `NotificationCenterCoordinator.shared` — son `start()` appelle
///   `NotificationChannel.start()` qui fait `open(…, O_TRUNC)` sur `notifications.jsonl` :
///   **il effacerait silencieusement le canal de la GUI en cours d'exécution.** Le plus vicieux.
/// - `IDEHost.shared` — prend le lock `~/.claude/ide/<port>.lock` sur tout `$HOME` : deux
///   IDE « valides » ⇒ plus aucune auto-connexion, des deux côtés.
/// - `IDELog.startSession()` — tronque `ide.log` de l'app vivante.
/// - `SessionStore` / `ScriptRunStore` / les `TerminalController` — tirent les vues SwiftTerm.
///   (`PTYProcess` n'utilise de SwiftTerm que `PseudoTerminalHelpers`, sans vue.)
/// - `Bundle.module` — `fatalError` en contexte bundlé.
///
/// `ScheduleStore.shared` n'est pas touché non plus : on passe par le **statique**
/// `ScheduleStore.loadFromDisk()`, qui n'instancie rien et n'arme aucune surveillance.
///
/// `claude` est lancé avec `--permission-mode dontAsk` et `CLAUDE_CODE_AUTO_CONNECT_IDE=false`
/// (cf. `ClaudeInvocation`) : personne n'est devant l'écran pour répondre à un prompt de
/// permission ni à la fenêtre de revue du pont IDE.
enum ScheduleRunner {

    // MARK: - Point d'entrée du drapeau

    /// Codes de sortie (conventions `sysexits.h`) :
    /// `64` argv invalide · `66` planification introuvable · `1` run en échec ou délai
    /// dépassé · `0` session terminée **ou** run sauté (un garde-fou qui joue n'est pas une
    /// panne, et launchd n'a pas à voir un échec là où le système s'est protégé).
    static func run(arguments: [String], flagIndex: Int) -> Never {
        let dryRun = arguments.contains("--dry-run")

        guard arguments.count > flagIndex + 1 else {
            fail("usage : potof-toolkit --run-schedule <uuid> [--dry-run]", code: 64)
        }
        let raw = arguments[flagIndex + 1]
        guard let scheduleID = UUID(uuidString: raw) else {
            fail("identifiant de planification invalide : « \(raw) »", code: 64)
        }

        let schedules = ScheduleStore.loadFromDisk()
        guard let schedule = schedules.first(where: { $0.id == scheduleID }) else {
            fail("planification introuvable : \(scheduleID.uuidString) "
                 + "(\(schedules.count) planification(s) dans \(SchedulePaths.schedulesFile.path))",
                 code: 66)
        }

        // Le plist pose `POTOF_SCHEDULE_TRIGGER=launchd`. Lancé à la main depuis un
        // terminal, la variable est absente : on le dit (« cli ») plutôt que de mentir,
        // et c'est ce qui empêche un essai manuel de déclencher une bannière système.
        let trigger = ProcessInfo.processInfo
            .environment[LaunchAgentPlist.triggerEnvironmentKey] ?? "cli"

        let outcome = executeReporting(schedule, trigger: trigger, dryRun: dryRun)
        print(outcome.report)
        exit(outcome.status == .failed || outcome.status == .timedOut ? 1 : 0)
    }

    // MARK: - Exécution

    /// Signature du contrat. Utilisée telle quelle par « Lancer maintenant »
    /// (`ScheduleStore.runNow`, sur une file de fond).
    @discardableResult
    static func execute(_ schedule: Schedule, trigger: String, dryRun: Bool) -> RunStatus {
        executeReporting(schedule, trigger: trigger, dryRun: dryRun).status
    }

    /// La séquence complète. Rend aussi le compte rendu, dont le `--dry-run` fait sa
    /// sortie encadrée.
    ///
    /// Dry-run (« Simuler ») : aucun PTY pour le préscript ni pour la session, aucun
    /// fichier écrit, aucun verrou. Seule lecture réelle : `claude mcp list`. Un garde-fou
    /// qui aurait arrêté un run réel est **annoté** et le plan continue — c'est justement
    /// quand quelque chose bloque qu'on a besoin de le voir en entier.
    static func executeReporting(_ schedule: Schedule, trigger: String, dryRun: Bool,
                                 host: RunnerHost = .live) -> (status: RunStatus, report: String) {
        let runID = UUID()
        let fm = FileManager.default
        let reporter = Reporter(
            dryRun: dryRun,
            log: dryRun ? nil : RunLog(runID: runID, scheduleID: schedule.id, trigger: trigger))

        /// Fin du run en réel ; simple annotation en dry-run (rend alors `nil`).
        func halt(_ status: RunStatus, _ message: String,
                  sessionID: String? = nil) -> (status: RunStatus, report: String)? {
            if dryRun {
                reporter.blocker(message)
                return nil
            }
            return reporter.conclude(status, message, schedule: schedule, trigger: trigger,
                                     sessionID: sessionID)
        }

        reporter.header(schedule: schedule, trigger: trigger, runID: runID)

        // ── 1. Ouverture du run ──────────────────────────────────────────────────
        // AVANT les garde-fous : même un run sauté forme une paire start/end complète dans
        // le JSONL et porte son déclencheur.
        reporter.start()

        // ── 2. Planification désactivée ──────────────────────────────────────────
        // Un plist peut survivre à une désactivation (fichier resté là, job encore
        // chargé). En revanche « Lancer maintenant » sur une planification désactivée
        // est un geste explicite de l'utilisateur : on l'exécute.
        if !schedule.enabled && trigger != "manual",
           let done = halt(.skipped, "planification désactivée") {
            return done
        }

        // ── 3. Verrou inter-process ──────────────────────────────────────────────
        // C'est LUI qui rend « Lancer maintenant » compatible avec un tir launchd
        // simultané : `flock` est partagé entre process, pas entre threads d'un seul.
        var lockDescriptor: Int32?
        if !dryRun {
            switch acquireLock(schedule.id) {
            case .acquired(let fd):
                lockDescriptor = fd
            case .busy:
                return reporter.conclude(.skipped, "un run est déjà en cours",
                                         schedule: schedule, trigger: trigger)
            case .unavailable(let why):
                // Verrou impossible à poser (disque, permissions) : on continue plutôt
                // que d'abandonner — l'exclusion est une protection, pas une condition.
                reporter.note("verrou indisponible (\(why)) — on continue sans exclusion")
            }
        }
        defer {
            if let lockDescriptor {
                flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }

        let folder = schedule.folderPath
        let environment = ClaudeInvocation.environment(base: ProcessInfo.processInfo.environment)
        let ttyURL = SchedulePaths.ttyFile(runID: runID)

        // ── 4. Dossier ───────────────────────────────────────────────────────────
        var isDirectory: ObjCBool = false
        let folderExists = fm.fileExists(atPath: folder, isDirectory: &isDirectory)
            && isDirectory.boolValue
        if !folderExists, let done = halt(.failed, "dossier introuvable : \(folder)") {
            return done
        }
        if dryRun {
            // Indicatif seulement : en réel, c'est la détection du dialogue dans le PTY
            // qui fait foi (étape 8).
            let trusted = ClaudeInvocation.isTrusted(
                folderPath: folder, claudeJSON: try? Data(contentsOf: ClaudeInvocation.claudeJSONURL))
            reporter.note("dossier : \(folder) — \(folderExists ? "existe" : "INTROUVABLE")")
            if trusted {
                reporter.note("approuvé par Claude : oui")
            } else {
                reporter.blocker("dossier non approuvé par Claude : ouvrez-le une fois dans Claude Launcher")
            }
        }

        // ── 5. Préscript ─────────────────────────────────────────────────────────
        // Attendu jusqu'au bout ; un code ≠ 0 ou un délai dépassé annule le run AVANT
        // `claude` — un préscript qui demande un mot de passe ne doit pas laisser partir
        // une session sur un dossier à moitié préparé.
        if schedule.preScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reporter.note("préscript : aucun")
        } else if dryRun {
            reporter.block("préscript (non exécuté, $SHELL -l -i -c dans le dossier)",
                           schedule.preScript)
        } else {
            appendBanner("\r\n── préscript ──\r\n", to: ttyURL)
            let result = PTYProcess.run(PTYRequest(
                executable: host.shell,
                arguments: ClaudeInvocation.shellArguments(shell: host.shell,
                                                           command: schedule.preScript),
                environment: environment,
                directory: folder,
                ttyFile: ttyURL,
                timeout: host.preScriptTimeout,
                stopMarker: nil,
                detectTrustDialog: false,
                keepOutput: false))
            switch result.end {
            case .exited(code: 0):
                reporter.note("préscript : terminé (code 0)")
            case .exited(let code):
                return reporter.conclude(.failed, "préscript en échec (code \(code))",
                                         schedule: schedule, trigger: trigger)
            case .timedOut:
                return reporter.conclude(.failed, "préscript : délai dépassé",
                                         schedule: schedule, trigger: trigger)
            case .spawnFailed:
                return reporter.conclude(.failed, "préscript : lancement impossible",
                                         schedule: schedule, trigger: trigger)
            case .stopped, .trustDialog:
                // Ni marqueur ni détection demandés : impossible, mais pas de `default`
                // muet pour autant.
                return reporter.conclude(.failed, "préscript : fin inattendue (\(result.end))",
                                         schedule: schedule, trigger: trigger)
            }
        }

        // ── 6. MCP requis ────────────────────────────────────────────────────────
        // `claude mcp list` et pas `-p` : en session interactive les MCP de plugin sont
        // gardés, c'est donc la liste qui reflète ce que la session aura.
        let required = schedule.requiredMCPServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if required.isEmpty {
            reporter.note("MCP requis : aucun")
        } else if !folderExists {
            reporter.note("claude mcp list : non exécuté (dossier introuvable)")
        } else {
            // ⚠️ stdout de `claude` sur un TUBE (`| cat`), pas sur le PTY. Mesuré le
            // 2026-10-30 (`claude` 2.1.314) : face à un terminal, `mcp list` remplace les
            // espaces par des déplacements de curseur (`ESC [ n G`), coupe les lignes à la
            // largeur de la grille et réécrit ses premières lignes — illisible pour
            // `MCPList.parse`. Sur un tube il imprime des lignes simples. Le shell de login
            // et l'environnement restent ceux de la session ; `pipefail` garde le code de
            // sortie de `claude` et non celui de `cat`.
            let command = "set -o pipefail; "
                + ClaudeInvocation.shellQuote(host.claudeCommand) + " mcp list | cat"
            let result = PTYProcess.run(PTYRequest(
                executable: host.shell,
                arguments: ClaudeInvocation.shellArguments(shell: host.shell, command: command),
                environment: environment,
                directory: folder,
                ttyFile: nil,
                timeout: host.mcpListTimeout,
                stopMarker: nil,
                detectTrustDialog: false,
                keepOutput: true))
            let states = MCPList.parse(String(decoding: result.output, as: UTF8.self))
            var problem: String?
            switch result.end {
            case .timedOut:
                problem = "claude mcp list : délai dépassé"
            case .spawnFailed:
                problem = "claude mcp list : lancement impossible"
            case .exited(let code) where code != 0 && states.isEmpty:
                problem = "claude mcp list en échec (code \(code))"
            default:
                reporter.note("claude mcp list : \(states.count) serveur(s) lu(s)")
                let missing = MCPList.unavailable(required: required, in: states)
                if missing.isEmpty {
                    reporter.note("MCP requis connectés : \(required.joined(separator: ", "))")
                } else {
                    problem = "MCP requis indisponibles : " + missing.joined(separator: ", ")
                }
            }
            if let problem, let done = halt(.failed, problem) { return done }
        }

        // ── 7. Settings du run ───────────────────────────────────────────────────
        // Ceux de la planification (facultatifs), plus le hook `Stop` qui pose le
        // marqueur : c'est lui qui dit « la réponse est finie », pas un délai.
        let settingsURL = SchedulePaths.runSettingsFile(runID: runID)
        let stopURL = SchedulePaths.stopMarker(runID: runID)
        var settingsReady = true
        var userSettings: Data?
        if let path = schedule.action.settingsPath {
            userSettings = try? Data(contentsOf: URL(fileURLWithPath: path))
            if userSettings == nil {
                settingsReady = false
                if let done = halt(.failed, "fichier de settings illisible : \(path)") { return done }
            }
        }
        if settingsReady {
            do {
                let data = try ClaudeInvocation.runSettings(userSettings: userSettings,
                                                            stopMarker: stopURL)
                if !dryRun {
                    SchedulePaths.ensureDirectories()
                    do {
                        try data.write(to: settingsURL)
                    } catch {
                        return reporter.conclude(
                            .failed, "settings du run impossibles à écrire : \(error.localizedDescription)",
                            schedule: schedule, trigger: trigger)
                    }
                }
                reporter.note("settings du run : \(settingsURL.path)")
            } catch {
                if let done = halt(.failed, "fichier de settings illisible : "
                                   + (schedule.action.settingsPath ?? "?")) {
                    return done
                }
            }
        }

        // ── 8. Session claude ────────────────────────────────────────────────────
        // Un `sessionID` neuf par run, toujours en minuscules : dans l'argv, dans la ligne
        // `end`, et pour retrouver la conversation (`claude --resume`).
        let sessionUUID = UUID()
        let sessionID = sessionUUID.uuidString.lowercased()
        let model = schedule.action.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeArguments = ClaudeInvocation.claudeArguments(
            prompt: schedule.action.prompt,
            sessionID: sessionUUID,
            settingsFile: settingsURL,
            model: model?.isEmpty == false ? model : nil,
            effort: schedule.action.effort)
        let argv = ClaudeInvocation.claudeShellArguments(
            shell: host.shell, claudeCommand: host.claudeCommand, claudeArguments: claudeArguments)
        reporter.argv(dryRun ? "argv de la session (sessionID d'exemple)" : "argv de la session", argv)

        if dryRun {
            reporter.block("prompt intégral", schedule.action.prompt)
            reporter.plist(schedule)
            // Le verdict reflète ce qu'un run RÉEL aurait fait : s'il se serait arrêté à
            // un garde-fou, on le dit — sinon le dry-run laisserait croire que tout est
            // prêt alors que rien ne partirait.
            return reporter.conclude(
                .skipped,
                reporter.blockers.isEmpty
                    ? "dry-run : rien n'a été lancé, mais un run réel irait au bout"
                    : "dry-run : un run réel s'arrêterait — "
                      + reporter.blockers.joined(separator: " ; "),
                schedule: schedule, trigger: trigger)
        }

        appendBanner("\r\n── claude ──\r\n", to: ttyURL)
        let timeout = host.sessionTimeoutOverride ?? TimeInterval(schedule.timeoutMinutes * 60)
        reporter.note("session \(sessionID) : délai \(Int(timeout)) s")
        let session = PTYProcess.run(PTYRequest(
            executable: host.shell,
            arguments: argv,
            environment: environment,
            directory: folder,
            ttyFile: ttyURL,
            timeout: timeout,
            stopMarker: stopURL,
            detectTrustDialog: true,
            keepOutput: false))

        let status: RunStatus
        let message: String
        switch session.end {
        case .stopped:
            status = .completed
            message = "session terminée"
        case .exited(let code):
            status = .failed
            message = "claude s'est arrêté avant la fin de sa réponse (code \(code))"
        case .timedOut:
            status = .timedOut
            message = "délai de \(schedule.timeoutMinutes) min dépassé"
        case .trustDialog:
            status = .failed
            message = "dossier non approuvé par Claude : ouvrez-le une fois dans Claude Launcher"
        case .spawnFailed:
            status = .failed
            message = "lancement impossible"
        }
        return reporter.conclude(status, message, schedule: schedule, trigger: trigger,
                                 sessionID: sessionID)
    }

    /// Bandeau de séparation dans le `.tty` : il est rejoué tel quel par la GUI.
    private static func appendBanner(_ text: String, to url: URL) {
        SchedulePaths.ensureDirectories()
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = write(fd, bytes, bytes.count)
    }

    // MARK: - Verrou

    enum LockOutcome: Equatable {
        case acquired(Int32)
        case busy
        case unavailable(String)
    }

    /// Interne (et non `private`) pour que l'auto-test puisse prouver l'exclusion, qui est
    /// la seule chose empêchant deux sessions de partir dans le même dossier.
    static func acquireLock(_ scheduleID: UUID) -> LockOutcome {
        SchedulePaths.ensureDirectories()
        let url = SchedulePaths.lockFile(scheduleID: scheduleID)
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            return .unavailable("open a rendu errno \(errno)")
        }
        // NON bloquant : un run déjà en cours doit rendre la main tout de suite, pas
        // empiler des process launchd en attente.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return errno == EWOULDBLOCK ? .busy : .unavailable("flock a rendu errno \(errno)")
        }
        return .acquired(fd)
    }

    // MARK: - Notification (§6.7)

    /// Bannière système sur `failed`/`skipped`/`timedOut`, et **uniquement** pour un tir
    /// launchd — « Lancer maintenant » n'a rien à notifier, l'utilisateur regarde déjà
    /// l'écran.
    ///
    /// ⚠️ Appelée **après** l'écriture de la ligne `end` du JSONL, jamais avant : un canal
    /// de notification défaillant ne doit pas coûter la trace du run.
    ///
    /// Décision **pure**, isolée pour être vérifiable sans faire apparaître de bannière.
    static func shouldNotify(status: RunStatus, trigger: String) -> Bool {
        trigger == LaunchAgentPlist.launchdTriggerValue && status.deservesNotification
    }

    @discardableResult
    static func notify(status: RunStatus, scheduleName: String,
                       message: String, trigger: String) -> String? {
        guard shouldNotify(status: status, trigger: trigger) else { return nil }

        // Le titre distingue les cas : un garde-fou qui joue n'est pas une panne, et les
        // confondre dans la bannière revient à crier au loup jusqu'à ne plus regarder.
        let title: String
        switch status {
        case .skipped:  title = "Claude Scheduler — run sauté"
        case .timedOut: title = "Claude Scheduler — délai dépassé"
        default:        title = "Claude Scheduler — échec"
        }
        return ScheduleNotifier.post(title: title, subtitle: scheduleName, body: message)
    }

    // MARK: - Compte rendu

    /// Écrit dans le JSONL **et** dans le log du run quand ce n'est pas un dry-run ;
    /// n'accumule que du texte en dry-run — un plan ne doit laisser aucune trace.
    private final class Reporter {
        private let dryRun: Bool
        private let log: RunLog?
        private var lines: [String] = []

        init(dryRun: Bool, log: RunLog?) {
            self.dryRun = dryRun
            self.log = log
        }

        func header(schedule: Schedule, trigger: String, runID: UUID) {
            let action = schedule.action
            lines.append("╭─ \(dryRun ? "DRY-RUN — aucun effet de bord" : "RUN") "
                         + "─────────────────────────────")
            lines.append("│  planification   \(schedule.name)")
            lines.append("│  identifiant     \(schedule.id.uuidString)")
            lines.append("│  déclencheur     \(trigger)")
            lines.append("│  run             \(runID.uuidString)")
            lines.append("│  cadence         \(LaunchAgentPlist.humanDescription(schedule.recurrence))")
            lines.append("│  dossier         \(schedule.folderPath)")
            lines.append("│  claude          modèle \(action.model ?? "par défaut")"
                         + " · effort \(action.effort ?? "par défaut")"
                         + " · délai \(schedule.timeoutMinutes) min")
            if let settingsPath = action.settingsPath {
                lines.append("│  settings        \(settingsPath)")
            }
            if !schedule.requiredMCPServers.isEmpty {
                lines.append("│  MCP requis      \(schedule.requiredMCPServers.joined(separator: ", "))")
            }
        }

        func start() { log?.start() }

        /// Garde-fou qui aurait arrêté un run réel. En dry-run **on continue** : c'est
        /// précisément quand quelque chose bloque qu'on a besoin de voir le plan entier.
        private(set) var blockers: [String] = []

        func blocker(_ text: String) {
            blockers.append(text)
            lines.append("│  ⚠︎ un run réel s'arrêterait ici : \(text)")
        }

        func note(_ text: String) {
            lines.append("│  \(text)")
            log?.note(text)
        }

        func argv(_ title: String, _ arguments: [String]) {
            lines.append("│")
            lines.append("│  \(title) — argv exact :")
            for (index, argument) in arguments.enumerated() {
                // Un argument multiligne (le prompt) reste lisible ligne à ligne.
                let shown = argument.replacingOccurrences(of: "\n", with: "\n│          ")
                lines.append(String(format: "│     [%02d] ", index) + shown)
            }
            log?.note("\(title) : \(arguments.count) argument(s)")
        }

        /// Texte multiligne encadré (préscript, prompt).
        func block(_ title: String, _ text: String) {
            lines.append("│")
            lines.append("│  \(title) :")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("│    \(line)")
            }
        }

        func plist(_ schedule: Schedule) {
            lines.append("│")
            lines.append("│  .plist qui serait installé :")
            let path = SchedulePaths.hostExecutableURL.path
            if let data = try? LaunchAgentPlist.data(for: schedule, executablePath: path),
               let xml = String(data: data, encoding: .utf8) {
                for line in xml.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("│    \(line)")
                }
            } else {
                lines.append("│    (génération impossible)")
            }
        }

        func conclude(_ status: RunStatus, _ message: String,
                      schedule: Schedule, trigger: String,
                      sessionID: String? = nil) -> (status: RunStatus, report: String) {
            log?.finish(status: status, message: message, sessionID: sessionID)
            if !dryRun {
                // Le sort de la bannière est TRACÉ dans le journal du run : c'est le seul
                // moyen de savoir, après coup, pourquoi une notification n'est pas arrivée.
                if let outcome = ScheduleRunner.notify(
                    status: status, scheduleName: schedule.name,
                    message: message, trigger: trigger) {
                    log?.note(outcome)
                    lines.append("│  \(outcome)")
                }
            }
            lines.append("│")
            lines.append("│  → \(status.rawValue.uppercased()) : \(message)")
            lines.append("╰─────────────────────────────────────────────────────────")
            return (status, lines.joined(separator: "\n"))
        }
    }

    // MARK: - Auto-test

    static func probe() -> String { ScheduleRunnerProbe.run() }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("run-schedule: \(message)\n".utf8))
        exit(code)
    }
}
