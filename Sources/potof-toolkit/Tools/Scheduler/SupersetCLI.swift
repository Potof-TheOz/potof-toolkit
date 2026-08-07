import Foundation

/// Enrobage synchrone de la CLI `superset` — **lot L1**.
///
/// Gabarit : `Git.swift` (chemin absolu, `arguments: [String]`, **aucun échappement**,
/// pipes lus AVANT `waitUntilExit`), plus deux ajouts que `Git.run` n'a pas :
/// - **timeout** (`DispatchWorkItem` + `asyncAfter` + `.cancel()`, modèle
///   `WorkingCopyStore.swift`) — un job launchd ne doit jamais rester pendu ;
/// - **décodage JSON** (`--json` passé explicitement partout).
///
/// ## Environnement à nettoyer avant tout `superset` (§6.3)
/// `run` hérite de l'environnement, pose `SchedulePaths.searchPath`, et **retire** :
///
/// | Variable | Pourquoi |
/// |---|---|
/// | `CLAUDE_CODE_SSE_PORT` | court-circuite la découverte des locks IDE : l'agent spawné se brancherait sur un port IDE **mort** hérité |
/// | `POTOF_SESSION_ID` | clé de mapping des notifications : héritée, elle attribuerait les events du nouvel agent à une session Potof sans rapport |
/// | `CI`, `CLAUDECODE` | la CLI passe « auto-on `--json` under CI/agent envs » ⇒ parsing non déterministe |
/// | `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` | détourneraient le `fetch`/`reset` vers un autre dépôt |
///
/// ⚠️ **Tout est bloquant.** `ensureHostServiceHealthy` peut dormir jusqu'à deux minutes.
/// À n'appeler que depuis le mode headless ou une file de fond, jamais du thread principal.
enum SupersetCLI {

    struct Result {
        let code: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { code == 0 }
        /// stderr si non vide, sinon stdout — le message le plus parlant à remonter.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
        }
    }

    struct HostStatus: Codable, Hashable {
        let healthy: Bool?
        let hostName: String?
    }

    /// Variables d'environnement à **supprimer** avant chaque invocation (§6.3).
    static let environmentDenyList = [
        "CLAUDE_CODE_SSE_PORT", "POTOF_SESSION_ID",
        "CI", "CLAUDECODE",
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"
    ]

    // MARK: - Budgets

    /// `status` interroge un service local : rapide, ou mort.
    static let statusTimeout: TimeInterval = 30
    /// Les `list` passent par le host service (HTTP loopback) : quelques centaines de ms.
    static let listTimeout: TimeInterval = 60
    /// `agents create` démarre un process d'agent : la CLI rend la main dès qu'il est lancé.
    static let createAgentTimeout: TimeInterval = 180
    /// `workspaces create` fait un `git worktree add` (et parfois un clone) : large.
    static let createWorkspaceTimeout: TimeInterval = 600
    /// Délai laissé au process après le `SIGTERM` du chien de garde, avant d'abandonner
    /// la lecture des pipes et de rendre un `Result` en échec.
    private static let terminationGrace: TimeInterval = 5

    // MARK: - Process

    /// Exécute `superset <args>`. **Bloquant**, jamais plus de `timeout` + grâce.
    ///
    /// Aucun shell, donc **aucun échappement** : un prompt multiligne portant des
    /// apostrophes, des backticks et des `$` passe tel quel dans `arguments`.
    static func run(_ args: [String], timeout: TimeInterval = 300) -> Result {
        guard let executable = SchedulePaths.supersetExecutablePath else {
            return Result(
                code: -1,
                stdout: "",
                stderr: "Superset introuvable : ni « \(SchedulePaths.supersetShimPath) » "
                    + "ni « \(SchedulePaths.supersetBundledPath) » n'est exécutable.")
        }
        return execute(executable, args, timeout: timeout)
    }

    static func isInstalled() -> Bool {
        SchedulePaths.supersetExecutablePath != nil
    }

    /// Environnement transmis à chaque process fils (§6.3). `PATH` est **remplacé**, pas
    /// complété : sous launchd il vaut `/usr/bin:/bin:/usr/sbin:/sbin` et `superset` y est
    /// introuvable ; ailleurs, un `PATH` hérité d'un shell d'agent n'apporte rien de plus
    /// que `SchedulePaths.searchPath`.
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in environmentDenyList { env.removeValue(forKey: key) }
        env["PATH"] = SchedulePaths.searchPath
        return env
    }

    /// Cœur du shell-out. Deux écarts assumés vis-à-vis de `Git.run` :
    ///
    /// 1. **Lecture des pipes sur des files de fond**, jointe *avant* `waitUntilExit()`.
    ///    `readDataToEndOfFile()` sur le thread appelant ne rend la main que lorsque
    ///    **tous** les descripteurs d'écriture sont fermés — or `superset start --daemon`
    ///    laisse un **petit-fils** (le daemon) hériter de stdout : le fils meurt, le pipe
    ///    reste ouvert, et un `readDataToEndOfFile()` direct ne reviendrait **jamais**.
    ///    Avec la lecture déportée, on abandonne au bout du budget au lieu de figer un job.
    /// 2. **Chien de garde** `DispatchWorkItem` + `asyncAfter` + `.cancel()` (modèle
    ///    `WorkingCopyStore.generateCommitMessage`) : `SIGTERM` à `timeout`.
    private static func execute(_ executable: String, _ args: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = childEnvironment()
        // Headless : rien à saisir. Un stdin hérité laisserait la CLI attendre
        // indéfiniment si elle réclamait une authentification.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(code: -1, stdout: "",
                          stderr: "Impossible de lancer superset : \(error.localizedDescription)")
        }

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.raise()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Lecture AVANT waitUntilExit (règle `Git.run`), mais déportée — cf. plus haut.
        let readers = DispatchGroup()
        let box = OutputBox()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            DispatchQueue.global(qos: .utility).async(group: readers) {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.store(data, isStdout: isStdout)
            }
        }

        let joined = readers.wait(timeout: .now() + timeout + terminationGrace) == .success
        watchdog.cancel()

        if !joined {
            // Les lecteurs restent bloqués jusqu'à la fermeture du pipe (petit-fils vivant) :
            // on ne les attend plus, mais on ne bloque pas non plus sur `waitUntilExit`.
            return timeoutResult(args, timeout: timeout, stdout: box.stdout)
        }
        process.waitUntilExit()

        // `terminationReason` départage la course du chien de garde : il a pu voir
        // `isRunning == true` sur un process qui finissait à cet instant précis. Seul un
        // process réellement abattu par le `SIGTERM` compte comme un dépassement.
        if timedOut.isRaised, process.terminationReason == .uncaughtSignal {
            return timeoutResult(args, timeout: timeout, stdout: box.stdout)
        }
        return Result(code: process.terminationStatus, stdout: box.stdout, stderr: box.stderr)
    }

    private static func timeoutResult(_ args: [String], timeout: TimeInterval,
                                      stdout: String) -> Result {
        let delay = timeout < 1 ? String(format: "%.2f", timeout) : String(Int(timeout))
        return Result(
            code: -1, stdout: stdout,
            stderr: "superset \(args.prefix(2).joined(separator: " ")) : délai dépassé (\(delay) s).")
    }

    /// Drapeau partagé entre le chien de garde et le thread appelant.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Collecteur des deux pipes, écrit depuis deux files concurrentes.
    private final class OutputBox {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func store(_ data: Data, isStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isStdout { out.append(data) } else { err.append(data) }
        }
        var stdout: String { lock.lock(); defer { lock.unlock() }; return String(data: out, encoding: .utf8) ?? "" }
        var stderr: String { lock.lock(); defer { lock.unlock() }; return String(data: err, encoding: .utf8) ?? "" }
    }

    // MARK: - Lectures

    /// `nil` = la CLI n'a rien rendu d'exploitable (Superset absent, host service mort,
    /// sortie non-JSON). ≠ « host service en mauvaise santé », qui est
    /// `HostStatus(healthy: false, …)`.
    static func hostStatus() -> HostStatus? {
        let result = run(["status", "--json"], timeout: statusTimeout)
        // Le code de sortie n'est pas un critère : `status` peut sortir en ≠ 0 tout en
        // imprimant un JSON parfaitement lisible qui dit « pas sain ».
        return decodeObject(result.stdout, as: HostStatus.self)
    }

    /// `open -g -a Superset` puis, en dernier recours, `superset start --daemon`.
    ///
    /// Ordre voulu : l'app Superset démarre elle-même son host service et c'est le chemin
    /// « normal » du poste ; `start --daemon` est le repli si l'app n'est pas installée ou
    /// refuse de se lancer. **Bloquant jusqu'à `timeout`.**
    static func ensureHostServiceHealthy(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        if isHealthy() { return true }

        // 1) Réveiller l'app (en arrière-plan : `-g` ne vole pas le focus à l'utilisateur).
        _ = runTool("/usr/bin/open", ["-g", "-a", "Superset"], timeout: 30)
        if poll(attempts: 30, interval: 3, deadline: deadline) { return true }

        // 2) Dernier recours : le daemon sans interface.
        _ = run(["start", "--daemon"], timeout: min(60, max(5, deadline.timeIntervalSinceNow)))
        if poll(attempts: 10, interval: 3, deadline: deadline) { return true }

        return false
    }

    static func projects() -> [SupersetProject] {
        // Liste plus permissive que `workspaces` : un projet illisible n'expose à aucun
        // effet de bord destructeur, il disparaît juste du sélecteur.
        decodeArray(run(["projects", "list", "--local", "--json"], timeout: listTimeout).stdout,
                    as: SupersetProject.self)?.items ?? []
    }

    /// ⚠️ `nil` = liste **ILLISIBLE** ≠ liste vide. La distinction est vitale : sur une
    /// liste illisible, un run `permanentWorkspace` doit **ABANDONNER** et surtout pas
    /// créer à l'aveugle — il dupliquerait le workspace permanent. Leçon directe du
    /// script de référence.
    ///
    /// Un **seul** élément indécodable suffit à rendre la liste illisible : c'est
    /// exactement l'élément manquant qui provoquerait la duplication.
    static func workspaces() -> [SupersetWorkspace]? {
        let result = run(["workspaces", "list", "--local", "--json"], timeout: listTimeout)
        guard let decoded = decodeArray(result.stdout, as: SupersetWorkspace.self),
              decoded.complete
        else { return nil }
        return decoded.items
    }

    /// Agents configurés sur l'hôte local : presets ET instances `HostAgentConfig`.
    /// `nil` = liste illisible → le formulaire retombe sur la saisie libre plutôt que de
    /// prétendre qu'il n'existe aucun agent.
    static func agentConfigs() -> [SupersetAgentConfig]? {
        let result = run(["agents", "list", "--local", "--json"], timeout: listTimeout)
        guard let decoded = decodeArray(result.stdout, as: SupersetAgentConfig.self),
              decoded.complete
        else { return nil }
        return decoded.items
    }

    // MARK: - Écritures

    /// argv de `workspaces create`. Isolé pour que le `--dry-run` du runner (L5) imprime
    /// **exactement** ce qui serait exécuté, sans dupliquer la construction.
    static func createWorkspaceArguments(projectID: String, name: String, branch: String,
                                         baseBranch: String?, agent: String?,
                                         prompt: String?) -> [String] {
        var args = ["workspaces", "create", "--json", "--local",
                    "--project", projectID,
                    "--name", name,
                    "--branch", branch]
        if let baseBranch, !baseBranch.isEmpty { args += ["--base-branch", baseBranch] }
        if let agent, !agent.isEmpty { args += ["--agent", agent] }
        // `--prompt` est OBLIGATOIRE dès que `--agent` est posé (contrat de la CLI).
        if let prompt, !prompt.isEmpty { args += ["--prompt", prompt] }
        return args
    }

    /// argv de `agents create`. ⚠️ Pas de `--local` ici : `agents create` n'expose que
    /// `--host` (défaut = cette machine).
    static func createAgentArguments(workspaceID: String, agent: String, effort: String?,
                                     prompt: String) -> [String] {
        var args = ["agents", "create", "--json",
                    "--workspace", workspaceID,
                    "--agent", agent]
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
        args += ["--prompt", prompt]
        return args
    }

    /// ⚠️ **Ne jamais parser la sortie** : le runner relit `workspaces()` après coup
    /// (§6.1 étape 7). Le `Result` conserve le `raw` (stdout/stderr) pour le journal du run,
    /// parce que la forme JSON de `create` n'est pas connue.
    static func createWorkspace(projectID: String, name: String, branch: String,
                                baseBranch: String?, agent: String?, prompt: String?) -> Result {
        run(createWorkspaceArguments(projectID: projectID, name: name, branch: branch,
                                     baseBranch: baseBranch, agent: agent, prompt: prompt),
            timeout: createWorkspaceTimeout)
    }

    /// Idem : seul le code de sortie fait foi, le `raw` part au journal.
    static func createAgent(workspaceID: String, agent: String, effort: String?,
                            prompt: String) -> Result {
        run(createAgentArguments(workspaceID: workspaceID, agent: agent,
                                 effort: effort, prompt: prompt),
            timeout: createAgentTimeout)
    }

    // MARK: - Santé

    private static func isHealthy() -> Bool {
        hostStatus()?.healthy == true
    }

    /// `attempts` tours de `interval` secondes, bornés par `deadline`.
    private static func poll(attempts: Int, interval: TimeInterval, deadline: Date) -> Bool {
        for _ in 0..<attempts {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: interval)
            if isHealthy() { return true }
        }
        return false
    }

    /// Shell-out vers un outil **autre que** `superset` (aujourd'hui `/usr/bin/open`),
    /// avec le même environnement nettoyé et le même chien de garde.
    private static func runTool(_ executable: String, _ args: [String],
                                timeout: TimeInterval) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(code: -1, stdout: "", stderr: "\(executable) introuvable.")
        }
        return execute(executable, args, timeout: timeout)
    }

    // MARK: - Décodage tolérant

    /// La forme de sortie de la CLI n'est **pas** un contrat public : on isole le premier
    /// bloc JSON de la sortie plutôt que d'exiger que la sortie entière en soit un (une
    /// bannière de mise à jour suffirait sinon à tout casser).
    private static func jsonPayload(_ raw: String, opening: Character, closing: Character) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: opening),
              let end = trimmed.lastIndex(of: closing),
              start < end
        else { return nil }
        return String(trimmed[start...end]).data(using: .utf8)
    }

    private static func decodeObject<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        guard let data = jsonPayload(raw, opening: "{", closing: "}") else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `nil` = **le tableau** est illisible. `complete == false` = le tableau est lisible
    /// mais au moins un élément ne l'est pas (l'appelant décide ce que ça vaut).
    private static func decodeArray<T: Decodable>(_ raw: String, as type: T.Type)
        -> (items: [T], complete: Bool)? {
        guard let data = jsonPayload(raw, opening: "[", closing: "]") else { return nil }
        guard let slots = try? JSONDecoder().decode([Lenient<T>].self, from: data) else { return nil }
        let items = slots.compactMap(\.value)
        return (items, items.count == slots.count)
    }

    /// Enveloppe qui absorbe l'échec d'**un** élément sans faire tomber le tableau.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: - Auto-test (`--sched-selftest cli`)

    /// Ouvre un workspace dans l'app Superset.
    ///
    /// ⭐ On appelle **la sous-commande**, jamais l'URL fabriquée à la main. `workspaces
    /// open <id> --print` révèle aujourd'hui `superset://v2-workspace/<id>`, mais ce
    /// format n'est pas un contrat — le nom même de la route (`v2-…`) annonce qu'elle a
    /// déjà changé une fois. La commande, elle, est documentée et stable ; c'est elle qui
    /// absorbera la prochaine migration.
    static func openWorkspace(id: String) -> Result {
        run(["workspaces", "open", id], timeout: 30)
    }

    static func probe() -> String {
        var lines: [String] = []
        lines.append("── SupersetCLI — auto-test (lot L1) ─────────────────────────────")

        guard let executable = SchedulePaths.supersetExecutablePath else {
            lines.append("Superset introuvable :")
            lines.append("  shim   : \(SchedulePaths.supersetShimPath)")
            lines.append("  bundle : \(SchedulePaths.supersetBundledPath)")
            return lines.joined(separator: "\n")
        }
        lines.append("Exécutable : \(executable)")
        lines.append("PATH posé  : \(SchedulePaths.searchPath)")
        lines.append("Env retiré : \(environmentDenyList.joined(separator: ", "))")
        lines.append("")

        // ── Host service ─────────────────────────────────────────────────────────
        if let status = hostStatus() {
            lines.append("Host service : \(status.healthy == true ? "SAIN" : "PAS SAIN")"
                         + " · hostName = \(status.hostName ?? "(null)")")
        } else {
            lines.append("Host service : ILLISIBLE (`status --json` n'a rien rendu de décodable)")
        }
        lines.append("")

        // ── Listes ───────────────────────────────────────────────────────────────
        let allProjects = projects()
        lines.append("Projets    : \(allProjects.count)"
                     + " · premier = \(allProjects.first?.name ?? "—")")

        let allWorkspaces = workspaces()
        switch allWorkspaces {
        case .none:
            lines.append("Workspaces : ILLISIBLE (nil) — un run `permanentWorkspace` ABANDONNERAIT")
        case .some(let list):
            lines.append("Workspaces : \(list.count) · premier = \(list.first?.name ?? "—")")
        }

        let allAgents = agentConfigs()
        switch allAgents {
        case .none:
            lines.append("Agents     : ILLISIBLE (nil) — le formulaire retombe en saisie libre")
        case .some(let list):
            lines.append("Agents     : \(list.count) · premier = \(list.first?.displayName ?? "—")")
        }
        lines.append("")

        // ── argv des deux modes de lancement, SANS exécuter ───────────────────────
        let project = allProjects.first
        let workspace = allWorkspaces?.first
        let agentRef = allAgents?.first?.id ?? Action.defaultAgentRef
        let samplePrompt =
            "Relève quotidienne : résume les erreurs de la nuit et écris le rapport du jour."

        lines.append("argv — cible « workspace permanent » (agents create) :")
        lines.append(contentsOf: render(createAgentArguments(
            workspaceID: workspace?.id ?? "<workspace-id>",
            agent: agentRef,
            effort: "xhigh",
            prompt: samplePrompt), executable: executable))
        if let workspace {
            lines.append("   (workspace échantillon : « \(workspace.name) » — "
                         + "worktree \(workspace.worktreePath ?? "?"))")
        }
        lines.append("")

        // ⭐ Nommage du mode « workspace neuf » : on appelle les helpers GELÉS du socle,
        // jamais une copie locale. Une copie a déjà divergé une fois — le probe affichait
        // une granularité à la minute alors que le runner était passé aux secondes, donc
        // l'aperçu mentait sur ce qui serait réellement créé.
        let now = Date()
        lines.append("argv — cible « nouveau workspace » (workspaces create) :")
        lines.append(contentsOf: render(createWorkspaceArguments(
            projectID: project?.id ?? "<project-id>",
            name: Target.freshWorkspaceName(prefix: "Relève Sentry", date: now),
            branch: Target.freshWorkspaceBranch(prefix: "Relève Sentry", date: now),
            baseBranch: nil,
            agent: agentRef,
            prompt: samplePrompt), executable: executable))
        if let project {
            lines.append("   (projet échantillon : « \(project.name) »)")
        }
        lines.append("")
        lines.append("Aucun `create` n'a été exécuté : ces deux argv sont imprimés, pas lancés.")
        lines.append("Aucun échappement n'est appliqué — `arguments: [String]`, pas de shell.")
        lines.append("")

        // ── AgentPresence, sur un worktree réel quand il y en a un ────────────────
        let worktree = workspace?.worktreePath.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        lines.append("AgentPresence.isAlive(\(worktree.path)) = "
                     + (AgentPresence.isAlive(in: worktree) ? "OUI" : "non"))
        lines.append(AgentPresence.probe())

        return lines.joined(separator: "\n")
    }

    /// Un argument par ligne, indexé — la forme demandée par la porte de sortie du lot.
    private static func render(_ args: [String], executable: String) -> [String] {
        var lines = ["   [--] \(executable)"]
        for (index, arg) in args.enumerated() {
            lines.append(String(format: "   [%02d] %@", index, arg))
        }
        return lines
    }
}

// MARK: - Modèles décodés

/// Décodage **tolérant** : la forme de sortie de la CLI n'est pas un contrat public.
///
/// Vérifié sur `superset 1.18.3` : `workspaces list --local --json` rend un tableau dont
/// chaque élément porte `id`, `name`, `branch`, `projectId`, `projectName`, `worktreePath`,
/// `worktreeExists` (plus `organizationId`, `hostId`, `type`, `taskId`, `createdAt`,
/// `updatedAt`, `createdByUserId`, ignorés ici).
struct SupersetWorkspace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let branch: String?
    let projectId: String?
    let projectName: String?
    let worktreePath: String?
    let worktreeExists: Bool?

    init(id: String, name: String, branch: String? = nil, projectId: String? = nil,
         projectName: String? = nil, worktreePath: String? = nil, worktreeExists: Bool? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.projectId = projectId
        self.projectName = projectName
        self.worktreePath = worktreePath
        self.worktreeExists = worktreeExists
    }

    /// Seul `id` est exigé : c'est la clé de `agents create --workspace`. Un workspace
    /// sans `id` est inutilisable, et c'est la seule raison de rejeter un élément.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        worktreeExists = try container.decodeIfPresent(Bool.self, forKey: .worktreeExists)
    }
}

/// `projects list --json` : `{ name, repo, path, id }`.
struct SupersetProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let repo: String?
    let path: String?

    init(id: String, name: String, repo: String? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.repo = repo
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        path = try container.decodeIfPresent(String.self, forKey: .path)
    }
}

/// Tout est optionnel sauf ce qui permet de construire un `--agent <ref>`.
///
/// ⚠️ **La CLI ne nomme pas ces champs `name` / `preset`.** Vérifié sur `superset 1.18.3` :
/// `agents list --local --json` rend `{ id, presetId, iconId, label, command, args,
/// promptTransport, promptArgs, env, order }`. On mappe donc `label` → `name` et
/// `presetId` → `preset`, en acceptant aussi les noms « naturels » au cas où la CLI
/// dériverait. `id` peut ne PAS être un UUID (l'entrée « Superset » a `id == "superset"`).
struct SupersetAgentConfig: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let preset: String?
    /// `args` de la configuration. Sert **uniquement** à savoir si l'agent charge un
    /// profil de permissions — c'est exactement le contrôle que fait le script de
    /// référence avant d'accepter de lancer une session non surveillée.
    let args: [String]?

    /// Libellé affichable dans le sélecteur.
    var displayName: String { name ?? preset ?? id }

    /// L'agent charge-t-il un fichier de permissions de portée session ?
    /// `false` ⇒ il tournera avec les permissions PAR DÉFAUT, ce qui n'est pas anodin
    /// pour un agent qui s'exécute seul toutes les nuits.
    var loadsCustomSettings: Bool {
        args?.contains("--settings") ?? false
    }

    init(id: String, name: String?, preset: String?, args: [String]? = nil) {
        self.id = id
        self.name = name
        self.preset = preset
        self.args = args
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, label, preset, presetId, args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .label)
        preset = try container.decodeIfPresent(String.self, forKey: .preset)
            ?? container.decodeIfPresent(String.self, forKey: .presetId)
        args = try container.decodeIfPresent([String].self, forKey: .args)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(preset, forKey: .preset)
    }
}
