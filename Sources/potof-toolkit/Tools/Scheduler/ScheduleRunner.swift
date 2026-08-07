import Foundation   // ⚠️ JAMAIS AppKit, JAMAIS SwiftUI — garantie STRUCTURELLE : avec ce
                    //    seul import, `NSApp` devient une erreur de compilation.

/// Mode **headless** du binaire : `potof-toolkit --run-schedule <uuid> [--dry-run]`.
///
/// Vit **avant** `NSApplication` (cf. `main.swift`) et ne revient jamais. Même contrat
/// que `IDESelfTest.run(arguments:flagIndex:)`.
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
/// - `SessionStore` / `ScriptRunStore` / les `TerminalController` — tirent SwiftTerm.
/// - `Bundle.module` — `fatalError` en contexte bundlé.
///
/// `ScheduleStore.shared` n'est pas touché non plus : on passe par le **statique**
/// `ScheduleStore.loadFromDisk()`, qui n'instancie rien et n'arme aucune surveillance.
enum ScheduleRunner {

    /// Fenêtre laissée au host service pour répondre (réveil de Superset.app compris).
    private static let hostServiceTimeout: TimeInterval = 150

    // MARK: - Point d'entrée du drapeau

    /// Codes de sortie (conventions `sysexits.h`) :
    /// `64` argv invalide · `66` planification introuvable · `1` run en échec ·
    /// `0` agent lancé **ou** run sauté (un garde-fou qui joue n'est pas une panne, et
    /// launchd n'a pas à voir un échec là où le système s'est protégé).
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
        exit(outcome.status == .failed ? 1 : 0)
    }

    // MARK: - Exécution

    /// Signature du contrat. Utilisée telle quelle par « Lancer maintenant »
    /// (`ScheduleStore.runNow`, sur une file de fond).
    @discardableResult
    static func execute(_ schedule: Schedule, trigger: String, dryRun: Bool) -> RunStatus {
        executeReporting(schedule, trigger: trigger, dryRun: dryRun).status
    }

    /// La séquence complète du §6.1. Rend aussi le compte rendu, dont le `--dry-run` fait
    /// sa sortie encadrée.
    static func executeReporting(_ schedule: Schedule, trigger: String,
                                 dryRun: Bool) -> (status: RunStatus, report: String) {
        let runID = UUID()
        let reporter = Reporter(
            dryRun: dryRun,
            log: dryRun ? nil : RunLog(runID: runID, scheduleID: schedule.id, trigger: trigger))

        reporter.header(schedule: schedule, trigger: trigger, runID: runID)

        // ── 1. Ouverture du run ──────────────────────────────────────────────────
        // Écart assumé au §6.1, qui plaçait `start()` après les deux garde-fous : on
        // ouvre AVANT, pour que même un run sauté forme une paire start/end complète
        // dans le JSONL et porte son déclencheur. Un `end` orphelin resterait lisible
        // (`fold` le gère) mais afficherait un déclencheur inconnu dans l'historique.
        reporter.start()

        // ── 2. Planification désactivée ──────────────────────────────────────────
        // Un plist peut survivre à une désactivation (fichier resté là, job encore
        // chargé). En revanche « Lancer maintenant » sur une planification désactivée
        // est un geste explicite de l'utilisateur : on l'exécute.
        if !schedule.enabled && trigger != "manual" {
            if dryRun {
                reporter.blocker("planification désactivée")
            } else {
                return reporter.conclude(.skipped, "planification désactivée",
                                         schedule: schedule, trigger: trigger)
            }
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

        // ── 4. Host service ──────────────────────────────────────────────────────
        guard SupersetCLI.isInstalled() else {
            return reporter.conclude(.failed, "Superset introuvable sur ce poste",
                                     schedule: schedule, trigger: trigger)
        }
        if dryRun {
            let healthy = SupersetCLI.hostStatus()?.healthy == true
            reporter.note("host service : \(healthy ? "SAIN" : "INJOIGNABLE — un run réel tenterait « open -g -a Superset » puis « superset start --daemon »")")
        } else {
            guard SupersetCLI.ensureHostServiceHealthy(timeout: hostServiceTimeout) else {
                return reporter.conclude(.failed, "host service injoignable",
                                         schedule: schedule, trigger: trigger)
            }
            reporter.note("host service : sain")
        }

        // ── 5. Résolution de la cible ────────────────────────────────────────────
        let resolution = resolveTarget(schedule, reporter: reporter, dryRun: dryRun)
        switch resolution {
        case .abort(let status, let message):
            return reporter.conclude(status, message, schedule: schedule, trigger: trigger)
        case .planned(let message):
            // Dry-run : la cible n'existe pas encore, donc aucun `workspaceID` à mettre
            // dans l'argv de `agents create`. On imprime malgré tout le reste du plan —
            // c'est justement quand quelque chose manque qu'on lit un dry-run.
            reporter.blocker(message)
            reporter.prompt(schedule.action.prompt)
            reporter.plist(schedule)
            return reporter.conclude(.skipped, message, schedule: schedule, trigger: trigger)
        case .resolved(let workspaceID, let worktree):
            reporter.note("workspace : \(workspaceID)")
            reporter.note("worktree  : \(worktree.path)")

            // ── 6. Garde worktree ────────────────────────────────────────────────
            var isDirectory: ObjCBool = false
            let worktreeExists = FileManager.default
                .fileExists(atPath: worktree.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if !worktreeExists {
                if dryRun {
                    reporter.blocker("worktree absent : \(worktree.path)")
                } else {
                    return reporter.conclude(
                        .failed, "worktree absent : \(worktree.path)",
                        schedule: schedule, trigger: trigger,
                        workspaceID: workspaceID)
                }
            }

            // ── 7. Garde « agent encore vif » ────────────────────────────────────
            // Seulement sur un workspace permanent : un workspace neuf ne peut pas
            // héberger d'agent d'un run précédent. Deux agents dans le même worktree
            // s'écrasent l'un l'autre.
            if case .permanentWorkspace = schedule.target, worktreeExists {
                if AgentPresence.isAlive(in: worktree) {
                    if dryRun {
                        // §8.1 : « agent encore vif ? OUI → un run réel sauterait ». On
                        // l'annonce et on continue d'imprimer le plan.
                        reporter.blocker("un agent claude vit encore dans le worktree")
                    } else {
                        return reporter.conclude(
                            .skipped, "un agent claude vit encore dans le worktree",
                            schedule: schedule, trigger: trigger,
                            workspaceID: workspaceID, worktreePath: worktree.path)
                    }
                } else {
                    reporter.note("garde agent vif : aucun agent dans ce worktree")
                }
            }

            // ── 8. Rafraîchissement — par le RUNNER, jamais par l'agent ──────────
            if case .permanentWorkspace(_, _, _, _, let baseBranch, let refresh) = schedule.target,
               refresh {
                guard let baseBranch, !baseBranch.isEmpty else {
                    return reporter.conclude(
                        .failed, "rafraîchissement demandé sans branche de base",
                        schedule: schedule, trigger: trigger,
                        workspaceID: workspaceID, worktreePath: worktree.path)
                }
                if dryRun {
                    reporter.note("rafraîchissement : git fetch origin --prune "
                                  + "puis git reset --hard origin/\(baseBranch) (non exécuté)")
                } else {
                    let fetch = Git.run(["fetch", "origin", "--prune"], in: worktree)
                    guard fetch.ok else {
                        return reporter.conclude(
                            .failed, "git fetch a échoué : \(fetch.message)",
                            schedule: schedule, trigger: trigger,
                            workspaceID: workspaceID, worktreePath: worktree.path)
                    }
                    // Pas de `git clean` : bien trop risqué sur un worktree permanent,
                    // où l'utilisateur peut avoir laissé des fichiers non suivis.
                    let reset = Git.run(["reset", "--hard", "origin/\(baseBranch)"], in: worktree)
                    guard reset.ok else {
                        return reporter.conclude(
                            .failed, "git reset --hard a échoué : \(reset.message)",
                            schedule: schedule, trigger: trigger,
                            workspaceID: workspaceID, worktreePath: worktree.path)
                    }
                    reporter.note("worktree remis à plat sur origin/\(baseBranch)")
                }
            }

            // ── 9. Lancement de l'agent ──────────────────────────────────────────
            let argv = SupersetCLI.createAgentArguments(
                workspaceID: workspaceID,
                agent: schedule.action.agentRef,
                effort: schedule.action.effort,
                prompt: schedule.action.prompt)
            reporter.argv("superset agents create", argv)

            if dryRun {
                reporter.prompt(schedule.action.prompt)
                reporter.plist(schedule)
                // Le verdict reflète ce qu'un run RÉEL aurait fait : s'il se serait
                // arrêté à un garde-fou, on le dit — sinon le dry-run laisserait croire
                // que tout est prêt alors que rien ne partirait.
                return reporter.conclude(
                    .skipped,
                    reporter.blockers.isEmpty
                        ? "dry-run : aucun agent lancé, mais un run réel irait au bout"
                        : "dry-run : un run réel s'arrêterait — "
                          + reporter.blockers.joined(separator: " ; "),
                    schedule: schedule, trigger: trigger,
                    workspaceID: workspaceID, worktreePath: worktree.path)
            }

            let created = SupersetCLI.createAgent(
                workspaceID: workspaceID,
                agent: schedule.action.agentRef,
                effort: schedule.action.effort,
                prompt: schedule.action.prompt)
            reporter.note("sortie de agents create : \(created.message)")

            guard created.ok else {
                return reporter.conclude(
                    .failed, "agents create a échoué (\(created.code)) : \(created.message)",
                    schedule: schedule, trigger: trigger,
                    workspaceID: workspaceID, worktreePath: worktree.path)
            }

            // ── 10. Succès : l'agent est LANCÉ, rien de plus n'est promis ────────
            return reporter.conclude(
                .launched, "agent \(schedule.action.agentRef) lancé",
                schedule: schedule, trigger: trigger,
                workspaceID: workspaceID, worktreePath: worktree.path)
        }
    }

    // MARK: - Résolution de la cible

    private enum Resolution {
        case resolved(workspaceID: String, worktree: URL)
        /// Dry-run : ce qui serait fait, sans le faire.
        case planned(String)
        case abort(RunStatus, String)
    }

    private static func resolveTarget(_ schedule: Schedule, reporter: Reporter,
                                      dryRun: Bool) -> Resolution {
        // ⚠️ `nil` = liste ILLISIBLE, ce qui n'est PAS une liste vide. Sur une liste
        // illisible on abandonne : créer à l'aveugle dupliquerait le workspace permanent.
        // Leçon payée en production, pas précaution théorique.
        guard let workspaces = SupersetCLI.workspaces() else {
            return .abort(.failed,
                          "liste des workspaces illisible — abandon (créer à l'aveugle "
                          + "dupliquerait le workspace permanent)")
        }
        reporter.note("workspaces lus : \(workspaces.count)")

        switch schedule.target {

        case .permanentWorkspace(let projectID, _, let workspaceName, let branch,
                                 let baseBranch, _):
            // ⭐ Matching sur (projectId, name), JAMAIS sur le nom seul : plusieurs
            // projets peuvent héberger un workspace homonyme — c'est le cas sur ce poste
            // avec « Sentry report », un par projet suivi.
            // ⚠️ Le nom n'est PAS unique, même dans un projet : Superset accepte deux
            // workspaces homonymes (vérifié en production). En choisir un « au hasard »
            // ferait travailler l'agent dans un worktree que l'utilisateur ne regarde
            // pas. On préfère abandonner en le disant.
            let matches = workspaces.filter {
                $0.projectId == projectID && $0.name == workspaceName
            }
            if matches.count > 1 {
                return .abort(.failed,
                              "\(matches.count) workspaces s'appellent « \(workspaceName) » "
                              + "dans ce projet : cible ambiguë, renommez-en un")
            }
            if let found = matches.first {
                guard let path = found.worktreePath, !path.isEmpty else {
                    return .abort(.failed, "le workspace « \(workspaceName) » n'a pas de worktree")
                }
                return .resolved(workspaceID: found.id, worktree: URL(fileURLWithPath: path))
            }

            let argv = SupersetCLI.createWorkspaceArguments(
                projectID: projectID, name: workspaceName, branch: branch,
                baseBranch: baseBranch, agent: nil, prompt: nil)
            reporter.argv("superset workspaces create", argv)

            if dryRun {
                return .planned("workspace « \(workspaceName) » absent → serait créé")
            }
            let created = SupersetCLI.createWorkspace(
                projectID: projectID, name: workspaceName, branch: branch,
                baseBranch: baseBranch, agent: nil, prompt: nil)
            guard created.ok else {
                return .abort(.failed, "création du workspace échouée : \(created.message)")
            }
            return relist(projectID: projectID, name: workspaceName,
                          knownBefore: Set(workspaces.map(\.id)), reporter: reporter)

        case .freshWorkspace(let projectID, _, let namePrefix, let branchPrefix, let baseBranch):
            // Plafond : on ne supprime JAMAIS automatiquement — détruire un workspace où
            // un agent travaille encore serait destructif. On refuse d'en créer un de plus.
            let prefix = Target.freshWorkspaceNamePrefix(namePrefix)
            let existing = workspaces.filter {
                $0.projectId == projectID && $0.name.hasPrefix(prefix)
            }.count
            reporter.note("workspaces « \(namePrefix) … » déjà présents : \(existing)"
                          + " (plafond \(Target.freshWorkspaceCap))")
            guard existing < Target.freshWorkspaceCap else {
                return .abort(.skipped,
                              "trop de workspaces accumulés (\(existing) ≥ "
                              + "\(Target.freshWorkspaceCap)), faites le ménage")
            }

            let now = Date()
            let name = Target.freshWorkspaceName(prefix: namePrefix, date: now)
            let branch = Target.freshWorkspaceBranch(
                prefix: branchPrefix.isEmpty ? namePrefix : branchPrefix, date: now)
            // `workspaces create` sait poser `--agent` et `--prompt` d'un coup, mais on ne
            // s'en sert pas : ça sauterait les gardes 6 à 8. Un seul chemin de lancement,
            // c'est un seul endroit où les garde-fous s'appliquent.
            let argv = SupersetCLI.createWorkspaceArguments(
                projectID: projectID, name: name, branch: branch,
                baseBranch: baseBranch, agent: nil, prompt: nil)
            reporter.argv("superset workspaces create", argv)

            if dryRun {
                return .planned("workspace « \(name) » serait créé (branche « \(branch) »)")
            }
            let created = SupersetCLI.createWorkspace(
                projectID: projectID, name: name, branch: branch,
                baseBranch: baseBranch, agent: nil, prompt: nil)
            guard created.ok else {
                return .abort(.failed, "création du workspace échouée : \(created.message)")
            }
            return relist(projectID: projectID, name: name,
                          knownBefore: Set(workspaces.map(\.id)), reporter: reporter)
        }
    }

    /// ⚠️ **On ne parse jamais la sortie de `create`** : sa forme JSON n'est pas un
    /// contrat public. On relit la liste, qui en est un — une seule forme de données à
    /// connaître, et c'est celle qu'on sait déjà décoder.
    private static func relist(projectID: String, name: String,
                               knownBefore: Set<String>,
                               reporter: Reporter) -> Resolution {
        guard let workspaces = SupersetCLI.workspaces() else {
            return .abort(.failed, "workspace créé mais liste illisible ensuite")
        }
        let candidates = workspaces.filter { $0.projectId == projectID && $0.name == name }

        // ⭐ On identifie le workspace qu'on VIENT de créer par **différence
        // d'identifiants**, jamais par son nom. Superset accepte deux workspaces
        // homonymes dans un même projet : chercher par nom après un `create` peut rendre
        // un workspace PRÉEXISTANT, et l'agent partirait alors dans le worktree de
        // quelqu'un d'autre pendant que celui qu'on vient de créer reste vide. C'est
        // exactement ce qui s'est produit en recette.
        let created = candidates.filter { !knownBefore.contains($0.id) }
        guard let found = created.first ?? (candidates.count == 1 ? candidates.first : nil) else {
            return .abort(.failed, candidates.isEmpty
                ? "workspace créé mais introuvable à la relecture"
                : "workspace créé mais impossible de distinguer le nouveau parmi "
                  + "\(candidates.count) homonymes")
        }
        if created.count > 1 {
            reporter.note("⚠︎ \(created.count) workspaces créés portent ce nom — le premier est retenu")
        }
        guard let path = found.worktreePath, !path.isEmpty else {
            return .abort(.failed, "workspace créé mais sans worktree")
        }
        reporter.note("workspace créé puis relu : \(found.id)")
        return .resolved(workspaceID: found.id, worktree: URL(fileURLWithPath: path))
    }

    // MARK: - Verrou

    enum LockOutcome: Equatable {
        case acquired(Int32)
        case busy
        case unavailable(String)
    }

    /// Interne (et non `private`) pour que l'auto-test puisse prouver l'exclusion, qui est
    /// la seule chose empêchant deux agents de partir dans le même worktree.
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

    /// Bannière système sur `failed`/`skipped`, et **uniquement** pour un tir launchd —
    /// « Lancer maintenant » n'a rien à notifier, l'utilisateur regarde déjà l'écran.
    ///
    /// La remise est déléguée à `ScheduleNotifier`, qui poste sous l'identité de l'app.
    /// L'implémentation précédente passait par `osascript` : elle sortait en 0 sans jamais
    /// rien délivrer (§ commentaire de `ScheduleNotifier`).
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

        // Le titre distingue les deux cas : un garde-fou qui joue n'est pas une panne, et
        // les confondre dans la bannière revient à crier au loup jusqu'à ne plus regarder.
        let title = status == .failed
            ? "Superset Scheduler — échec"
            : "Superset Scheduler — run sauté"
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
            lines.append("╭─ \(dryRun ? "DRY-RUN — aucun effet de bord" : "RUN") "
                         + "─────────────────────────────")
            lines.append("│  planification   \(schedule.name)")
            lines.append("│  identifiant     \(schedule.id.uuidString)")
            lines.append("│  déclencheur     \(trigger)")
            lines.append("│  run             \(runID.uuidString)")
            lines.append("│  cadence         \(LaunchAgentPlist.humanDescription(schedule.recurrence))")
            lines.append("│  agent           \(schedule.action.agentRef)"
                         + (schedule.action.effort.map { " · effort \($0)" } ?? ""))
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
            lines.append("│     [--] \(SchedulePaths.supersetExecutablePath ?? "(superset introuvable)")")
            for (index, argument) in arguments.enumerated() {
                lines.append(String(format: "│     [%02d] %@", index, argument))
            }
            log?.note("\(title) : \(arguments.count) argument(s)")
        }

        func prompt(_ text: String) {
            lines.append("│")
            lines.append("│  prompt intégral :")
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
                      workspaceID: String? = nil,
                      worktreePath: String? = nil) -> (status: RunStatus, report: String) {
            log?.finish(status: status, message: message,
                        workspaceID: workspaceID, worktreePath: worktreePath)
            if !dryRun {
                // Le sort de la bannière est TRACÉ dans le journal du run. C'est ce qui
                // manquait : l'ancienne implémentation ne pouvait pas dire qu'elle n'avait
                // rien délivré, donc l'absence de notification restait inexplicable.
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
