import Foundation

/// « Un agent `claude` vit-il encore dans ce worktree ? » — **lot L1**.
///
/// Garde-fou du §6.1 étape 9 : sur une cible `permanentWorkspace`, relancer un agent
/// alors qu'un précédent travaille encore dans le même worktree, c'est deux agents qui
/// s'écrasent l'un l'autre.
///
/// ## Implémentation attendue
/// 1. `/usr/bin/pgrep -fl claude` → lignes « pid argv ».
/// 2. Retenir les pids dont le **PREMIER token** a pour dernier composant `claude`
///    **OU** contient `/claude/versions/` (le vrai binaire vit dans
///    `~/.local/share/claude/versions/`, lancé par le shim `~/.local/bin/claude`).
///    ⚠️ **Ne PAS ancrer sur la fin de la ligne d'arguments.**
/// 3. Pour chaque pid : `/usr/sbin/lsof -a -p <pid> -d cwd -Fn` → ligne « n<chemin> ».
///    Modèle : `Core/IDEHost/IDEClientIdentity.swift`.
/// 4. Comparer après `resolvingSymlinksInPath()` + `standardized` — `/private/var` contre
///    `/var`, sinon deux chemins identiques ne matchent pas.
///
/// ## La correction que le script de référence appelle
/// Le bash fait `pgrep -f '/\.local/bin/claude$'`. **Cette regex est cassée** : elle
/// trouve `4474 /Users/…/.local/bin/claude` (sans argument, ancré `$`) mais **manque**
/// `36383 /Users/…/.local/bin/claude --effort xhigh <prompt>` — dès qu'il y a des
/// arguments, le `$` ne matche plus. Un agent lancé avec des arguments passait donc sous
/// le radar : exactement le cas qu'on veut attraper.
///
/// ## Ce sur quoi on ne construit RIEN
/// Le champ `exited` des terminaux Superset **ne dit pas** si l'agent a fini : le shell
/// survit à la sortie de `claude` et reste `exited: false` des heures après (vérifié le
/// 2026-07-30). **La mort du process est la seule condition qui fasse foi.**
///
/// ⚠️ **Bloquant** (deux shell-outs par candidat, bornés) : appeler depuis le mode
/// headless ou une file de fond.
enum AgentPresence {

    /// Vrai dès qu'un process `claude` a son répertoire de travail **dans** `worktree`.
    ///
    /// « Dans », et pas « égal à » : un agent qui a fait un `cd` dans un sous-dossier
    /// travaille toujours dans le même worktree. L'asymétrie des erreurs impose ce choix —
    /// un faux positif fait sauter un run (`skipped`, réversible), un faux négatif lance un
    /// deuxième agent par-dessus le premier (deux agents qui s'écrasent, irréversible).
    static func isAlive(in worktree: URL) -> Bool {
        let target = canonicalPath(worktree)
        guard !target.isEmpty else { return false }
        for pid in claudePIDs() {
            guard let cwd = workingDirectory(ofPID: pid) else { continue }
            if isSameOrDescendant(canonicalPath(cwd), of: target) { return true }
        }
        return false
    }

    // MARK: - Chemins

    /// `resolvingSymlinksInPath()` **puis** `standardized`, sans barre finale.
    /// `/var/…` et `/private/var/…` désignent le même dossier sur macOS : sans cette
    /// normalisation, deux chemins identiques ne matchent pas.
    static func canonicalPath(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardized
        var path = resolved.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Comparaison **par composant** : `/a/b` contient `/a/b/c` mais pas `/a/bc`.
    static func isSameOrDescendant(_ candidate: String, of root: String) -> Bool {
        if candidate == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    // MARK: - Découverte des process

    /// Pids des process `claude` vivants (l'agent lui-même comme son shim).
    static func claudePIDs() -> [Int32] {
        guard let pgrep = executablePath(among: ["/usr/bin/pgrep", "/usr/sbin/pgrep"]),
              // `-f` : matcher la ligne de commande complète ; `-l` : l'imprimer.
              // Aucun motif ancré ici — le filtrage se fait en Swift (cf. en-tête).
              let output = run(pgrep, ["-fl", "claude"], timeout: pgrepTimeout)
        else { return [] }
        return parsePgrep(output)
    }

    /// Parse la sortie de `pgrep -fl` : une ligne « `<pid> <argv…>` » par process.
    ///
    /// ⚠️ **Les lignes ne sont pas fiables comme unité** : un agent lancé avec un prompt
    /// multiligne (le cas courant du poste) étale ses arguments sur des dizaines de lignes.
    /// D'où le filtre : une ligne ne compte que si son premier token est **entièrement
    /// numérique** et son deuxième token est un chemin d'exécutable `claude` reconnu. Une
    /// ligne de prompt tombe d'elle-même (« actuellement… » n'est pas un nombre ; « 50% du
    /// parc » non plus).
    static func parsePgrep(_ output: String) -> [Int32] {
        var pids: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2,
                  tokens[0].allSatisfy(\.isNumber),
                  let pid = Int32(tokens[0]),
                  isClaudeExecutable(String(tokens[1]))
            else { continue }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids
    }

    /// Le **premier token d'argv** désigne-t-il un `claude` ?
    ///
    /// Deux formes coexistent sur le poste :
    /// - `/Users/…/.local/bin/claude` (shim) et
    ///   `/Users/…/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude` → dernier
    ///   composant `claude` ;
    /// - `/Users/…/.local/share/claude/versions/2.1.222` → dernier composant = la
    ///   **version**, d'où la seconde condition sur `/claude/versions/`.
    static func isClaudeExecutable(_ argv0: String) -> Bool {
        if argv0.contains("/claude/versions/") { return true }
        let lastComponent = argv0.split(separator: "/").last.map(String.init) ?? argv0
        return lastComponent == "claude"
    }

    /// cwd du process `pid` via `lsof`. `nil` si le process est mort, si `lsof` manque, ou
    /// si la sortie n'est pas exploitable — jamais d'exception, jamais de crash.
    ///
    /// Même choix que `IDEClientIdentity` : `ps eww` ne rend plus l'environnement d'un
    /// process tiers depuis macOS 15, et `proc_pidinfo` exige des droits que l'app n'a pas.
    /// `lsof` (setgid) est le seul chemin fiable sans entitlement.
    static func workingDirectory(ofPID pid: Int32) -> URL? {
        guard pid > 0 else { return nil }
        guard let lsof = executablePath(among: ["/usr/sbin/lsof", "/usr/bin/lsof", "/usr/local/bin/lsof"]),
              let output = run(lsof, ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: lsofTimeout)
        else { return nil }
        return parseLsofCwd(output)
    }

    /// Sortie « machine » de `lsof -F` : un champ par ligne, préfixé de sa lettre
    /// (`p<pid>`, `f<fd>`, `n<chemin>`). On ignore tout ce qui n'est pas une ligne `n`
    /// absolue — `lsof` bavarde des avertissements de `stat()` sur les montages
    /// temporaires, qui partent sur stderr (jeté) mais qu'une version future pourrait
    /// mélanger ici.
    static func parseLsofCwd(_ output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            guard path.hasPrefix("/") else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Shell-outs

    /// `pgrep` scanne la table des process : quelques dizaines de ms.
    private static let pgrepTimeout: TimeInterval = 3
    /// `lsof` interroge la table des fichiers ouverts du noyau, mais un process bloqué en
    /// I/O peut le faire traîner. Même budget que `IDEClientIdentity`.
    private static let lsofTimeout: TimeInterval = 1.5

    /// Premier chemin **exécutable** de la liste. Volontairement pas de `PATH` : sous
    /// launchd il est minimal, et l'app n'a pas celui de l'utilisateur.
    private static func executablePath(among candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Exécute un binaire et rend sa sortie standard, ou `nil` (échec de lancement, code
    /// de sortie ≠ 0 sans sortie, dépassement du délai). stderr est jeté.
    ///
    /// Lecture sur une file dédiée : lire **après** `waitUntilExit()` interbloque dès que
    /// la sortie dépasse le tampon du pipe (64 Kio) — et `pgrep -fl` sur ce poste sort
    /// déjà plusieurs kilo-octets de prompts.
    private static func run(_ executable: String, _ arguments: [String],
                            timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var collected = Data()
        let lock = NSLock()
        let reader = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: reader) {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = data; lock.unlock()
        }
        guard reader.wait(timeout: .now() + timeout + 1) == .success else {
            watchdog.cancel()
            return nil
        }
        process.waitUntilExit()
        watchdog.cancel()

        lock.lock(); defer { lock.unlock() }
        // `pgrep` sort en 1 quand rien ne matche : sortie vide, pas une erreur.
        return String(data: collected, encoding: .utf8)
    }

    // MARK: - Auto-test (imprimé par `SupersetCLI.probe()`)

    /// Inventaire lisible de ce que la détection voit **maintenant**. Lecture seule.
    static func probe() -> String {
        let pids = claudePIDs()
        var lines = ["AgentPresence : \(pids.count) process `claude` détecté(s)"]
        for pid in pids {
            let cwd = workingDirectory(ofPID: pid).map(canonicalPath) ?? "(cwd illisible)"
            lines.append("   pid \(pid) → \(cwd)")
        }
        if pids.isEmpty {
            lines.append("   (aucun — `pgrep -fl claude` n'a rien rendu d'exploitable)")
        }
        return lines.joined(separator: "\n")
    }
}
