import Foundation

/// **Qui** est l'agent au bout de la connexion ?
///
/// L'utilisateur fait tourner 4–5 `claude` en parallèle (constaté) : une demande de
/// revue anonyme est inexploitable. Le protocole ne donne qu'un `pid` (notification
/// `ide_connected`) ; tout le reste se déduit :
///
/// ```
/// pid ──lsof──▶ cwd ──▶ ~/.superset/worktrees/<id>/<branche>  → « Superset · <branche> »
///                    └▶ racine git la plus proche              → « <repo> · <branche> »
///                    └▶ (rien)                                 → nom du dossier
/// ```
///
/// ⚠️ Le cwd s'obtient par `lsof -a -p <pid> -d cwd -Fn` : **vérifié sur ce poste**, ça
/// fonctionne sans privilège particulier et sort une ligne `n<chemin>`. `ps eww -p <pid>`
/// ne renvoie **plus** l'environnement d'un process tiers depuis le durcissement macOS 15
/// (sortie vide côté env) — ne pas y revenir. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` serait
/// l'appel « propre », mais il exige les mêmes droits que le `ps` d'antan pour un process
/// d'un autre groupe de session : `lsof` (setgid) est le seul chemin fiable sans
/// entitlement, et l'App Sandbox est de toute façon désactivée (invariant projet).
///
/// **Coût** : au pire **deux** shell-outs (`lsof`, puis `git` si la branche n'a pas pu être
/// lue à même `HEAD`), bornés à ``resolveTimeBudget`` au total, et **une seule fois par
/// connexion** (l'hôte mémorise l'identité dans son état de client). Le cas courant est
/// **un seul** shell-out : la branche se lit directement dans le fichier `HEAD`.
///
/// ⚠️ `resolve` **bloque** le thread appelant le temps des shell-outs : l'appeler depuis
/// une file de travail (celle de la connexion), jamais depuis le thread principal. En
/// `DEBUG` un appel sur le thread principal se signale sur la sortie d'erreur.
///
/// Type **valeur** et résolution **pure vis-à-vis de l'app** (elle ne lit que le
/// système de fichiers et le process externe) : testable et sans état partagé.
struct IDEClientIdentity {
    /// Pid du `claude` distant, si `ide_connected` l'a fourni.
    let pid: Int32?
    /// Répertoire de travail résolu depuis le pid (ou déduit du fichier édité).
    let cwd: URL?
    /// Libellé affiché : « Superset · <branche> », « <repo> · <branche> », ou à défaut
    /// le nom du dossier. Jamais vide (repli ultime : « Agent Claude »).
    let label: String
    /// Vrai si le cwd est sous `~/.superset/worktrees/` — l'UI peut le signaler
    /// (icône / couleur) puisque c'est le cas d'usage principal de l'hôte.
    let isSuperset: Bool

    /// Budget de blocage maximal de ``resolve`` (les deux shell-outs cumulés).
    static let resolveTimeBudget: TimeInterval = lsofTimeout + gitTimeout

    /// Résout au mieux, sans jamais échouer : `fallbackFilePath` (le chemin de l'
    /// `openDiff` en cours) sert de filet quand le pid est absent ou déjà mort.
    ///
    /// Le `fallbackFilePath` n'est pas traité comme un cas dégénéré à part : son dossier
    /// parent devient le **cwd présumé** et repasse par la même dérivation. Un `openDiff`
    /// sur un fichier d'un worktree Superset donne donc quand même « Superset · <branche> »
    /// plutôt que le seul nom du dossier — même information, obtenue autrement.
    static func resolve(pid: Int32?, fallbackFilePath: String?) -> IDEClientIdentity {
        #if DEBUG
        if Thread.isMainThread {
            FileHandle.standardError.write(Data(
                "[IDEClientIdentity] resolve() sur le thread principal : jusqu'à \(resolveTimeBudget) s de blocage.\n"
                    .utf8))
        }
        #endif

        // 1) Le cwd du process, s'il vit encore. 2) À défaut le dossier du fichier édité.
        let directory = pid.flatMap(workingDirectory(ofPID:)) ?? parentDirectory(ofFilePath: fallbackFilePath)

        guard let directory else {
            // Ni pid exploitable ni chemin de fichier : on assume l'anonymat.
            return IDEClientIdentity(pid: pid, cwd: nil, label: unknown.label, isSuperset: false)
        }

        let (label, isSuperset) = describe(directory: directory)
        return IDEClientIdentity(pid: pid, cwd: directory, label: label, isSuperset: isSuperset)
    }

    /// Identité neutre : connexion établie mais pas encore identifiée (avant
    /// `ide_connected`, ou pid disparu).
    static let unknown = IDEClientIdentity(
        pid: nil, cwd: nil, label: "Agent Claude", isSuperset: false)

    // MARK: - Dérivation du libellé

    /// Le cœur testable : un dossier → un libellé. Aucun accès process, uniquement le
    /// disque (et un `git` de secours pour la branche).
    static func describe(directory: URL) -> (label: String, isSuperset: Bool) {
        // (1) Worktree Superset : le cas d'usage principal de l'hôte, donc prioritaire.
        //     La branche est le seul discriminant utile entre 4–5 agents qui travaillent
        //     tous sur le même dépôt.
        if let branch = supersetBranch(for: directory) {
            return ("Superset · \(branch)", true)
        }

        // (2) Dépôt git quelconque (terminal du poste, session embarquée…).
        if let root = gitRoot(from: directory) {
            let repo = root.lastPathComponent
            if !repo.isEmpty, repo != "/" {
                if let branch = gitBranch(atRoot: root) {
                    return ("\(repo) · \(branch)", false)
                }
                // Branche illisible (HEAD détachée, worktree orphelin dont le dépôt
                // principal a disparu…) : le nom du dépôt reste informatif.
                return (repo, false)
            }
        }

        // (3) Hors git : le nom du dossier vaut mieux que rien.
        let name = directory.lastPathComponent
        if !name.isEmpty, name != "/" { return (name, false) }

        // (4) Cas pathologique (cwd == « / ») : anonymat.
        return (unknown.label, false)
    }

    /// `~/.superset/worktrees/<workspaceId>/<segments de branche…>` → la branche.
    ///
    /// Deux subtilités constatées sur le poste :
    /// - la branche **contient des `/`** (`superset/ide-diff-validation` → deux niveaux de
    ///   dossiers) mais pas toujours (`kaput-moth` → un seul) : on ne peut pas couper à une
    ///   profondeur fixe ;
    /// - le cwd de l'agent peut être un **sous-dossier** du worktree
    ///   (`…/ide-diff-validation/Sources/…`), il faut donc s'arrêter à la racine.
    ///
    /// On tranche par le disque : la racine du worktree est le premier dossier, en
    /// descendant, qui porte un `.git` (ici un **fichier** `gitdir: …`, pas un dossier).
    /// Si aucun `.git` n'apparaît (worktree effacé, chemin fantôme), on retombe sur la
    /// lecture littérale « tout ce qui suit l'identifiant de workspace ».
    static func supersetBranch(for directory: URL) -> String? {
        let rootComponents = supersetWorktreesRoot.pathComponents
        let components = directory.standardizedFileURL.pathComponents

        // Il faut au minimum : <racine>/<workspaceId>/<un segment de branche>.
        guard components.count >= rootComponents.count + 2 else { return nil }
        guard Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }

        // On ne valide pas `components[rootComponents.count]` comme UUID : seule sa
        // POSITION fait le contrat (Superset pourrait changer de format d'identifiant).
        let workspaceID = components[rootComponents.count]
        var segments = Array(components.dropFirst(rootComponents.count + 1))

        var probe = supersetWorktreesRoot.appendingPathComponent(workspaceID, isDirectory: true)
        for (index, segment) in segments.enumerated() {
            probe.appendPathComponent(segment)
            if hasGitEntry(probe) {
                segments = Array(segments.prefix(index + 1))
                break
            }
        }

        let branch = segments.joined(separator: "/")
        return branch.isEmpty ? nil : branch
    }

    /// Racine git la plus proche en **remontant** : le premier ancêtre (cwd inclus) qui
    /// porte un `.git`. Fichier **ou** dossier : un worktree et un sous-module ont un
    /// `.git` fichier, ne pas tester `isDirectory`.
    static func gitRoot(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        // Borne dure : un chemin pathologique (lien symbolique circulaire résolu en
        // boucle) ne doit pas transformer une résolution d'identité en boucle infinie.
        for _ in 0..<64 {
            if hasGitEntry(current) { return current }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }  // on a atteint « / »
            current = parent
        }
        return nil
    }

    /// Branche courante d'une racine git, **sans dépendance externe**.
    ///
    /// On lit d'abord `HEAD` à la main (aucun process à lancer, donc gratuit) ; le
    /// shell-out `git rev-parse` n'est qu'un secours pour les configurations exotiques.
    /// `nil` si HEAD est détachée (un SHA, aucun nom à afficher) ou si tout échoue.
    static func gitBranch(atRoot root: URL) -> String? {
        if let branch = branchFromHeadFile(root) { return branch }

        guard let git = executablePath(among: ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]),
              let output = run(git, ["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: gitTimeout)
        else { return nil }

        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // « HEAD » = état détaché ; une ligne vide = échec silencieux.
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    // MARK: - Lecture git à la main

    /// `<root>/.git` → `HEAD` → `ref: refs/heads/<branche>`.
    ///
    /// Gère les deux formes de `.git` : **dossier** (dépôt classique) et **fichier**
    /// `gitdir: <chemin>` (worktree lié, sous-module) — c'est exactement le cas des
    /// worktrees Superset.
    private static func branchFromHeadFile(_ root: URL) -> String? {
        let dotGit = root.appendingPathComponent(".git")
        var gitDir = dotGit

        // Lire un DOSSIER lève : l'échec vaut donc « `.git` est un dossier », pas une erreur.
        if let raw = try? String(contentsOf: dotGit, encoding: .utf8),
           let line = raw.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) {
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            // `gitdir:` est absolu en pratique, mais la spec autorise le relatif.
            gitDir = target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : root.appendingPathComponent(target).standardizedFileURL
        }

        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }  // worktree orphelin : le dépôt principal a disparu.

        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }  // sinon : SHA = HEAD détachée.
        let branch = String(trimmed.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// `.git` présent, quelle que soit sa nature (fichier de worktree ou dossier).
    private static func hasGitEntry(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }

    // MARK: - cwd d'un process tiers

    /// cwd du process `pid` via `lsof`. `nil` si le process est mort, si `lsof` manque,
    /// ou si la sortie n'est pas exploitable — jamais d'exception, jamais de crash.
    static func workingDirectory(ofPID pid: Int32) -> URL? {
        guard pid > 0 else { return nil }
        guard let lsof = executablePath(among: ["/usr/sbin/lsof", "/usr/bin/lsof", "/usr/local/bin/lsof"]),
              let output = run(lsof, ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: lsofTimeout)
        else { return nil }
        return parseLsofCwd(output)
    }

    /// Parse la sortie « machine » de `lsof -F` : un champ par ligne, préfixé de sa lettre
    /// (`p<pid>`, `f<fd>`, `n<chemin>`). Tolérant par construction : on ignore tout ce qui
    /// n'est pas une ligne `n` absolue et on garde la première (`-d cwd` n'en produit
    /// qu'une, mais `lsof` sait aussi émettre des avertissements — ils partent sur stderr,
    /// que l'on jette, et une version future pourrait les mélanger ici).
    static func parseLsofCwd(_ output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            guard path.hasPrefix("/") else { continue }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return nil
    }

    /// Dossier parent d'un chemin de fichier (le `oldPath` de l'`openDiff`).
    private static func parentDirectory(ofFilePath path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        return parent.path == "/" ? nil : parent
    }

    // MARK: - Shell-outs

    /// `lsof` interroge la table des fichiers ouverts du noyau : c'est rapide, mais un
    /// process bloqué en I/O peut le faire traîner. 1,5 s couvre très largement le cas
    /// nominal (~30 ms mesuré) sans jamais figer une revue de diff.
    private static let lsofTimeout: TimeInterval = 1.5
    /// `git rev-parse` n'est qu'un secours (la lecture de `HEAD` suffit presque toujours) :
    /// budget plus serré.
    private static let gitTimeout: TimeInterval = 1.0

    /// Premier chemin **exécutable** de la liste. On n'utilise volontairement PAS `PATH`
    /// ni un shell de connexion : l'app n'a pas le `PATH` de l'utilisateur (invariant
    /// projet, cf. `docs/SESSIONS.md`) et lancer un shell pour ça coûterait plus cher que
    /// la mesure elle-même.
    private static func executablePath(among candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Exécute un binaire et rend sa sortie standard, ou `nil` (échec de lancement,
    /// dépassement du délai). stderr est jeté : `lsof` bavarde des avertissements de
    /// `stat()` sur les montages temporaires, ce n'est pas une erreur.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // stdin fermé : aucun de ces outils n'en attend, et un stdin hérité pourrait les
        // faire patienter indéfiniment (git en particulier, s'il réclamait des creds).
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // La lecture se fait sur une file dédiée : lire APRÈS `waitUntilExit()` interbloque
        // dès que la sortie dépasse le tampon du pipe (64 Kio). Ici la sortie est minuscule,
        // mais la règle vaut mieux que le pari.
        var collected = Data()
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = data; lock.unlock()
            process.waitUntilExit()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // Escalade : SIGTERM, puis SIGKILL si le process l'ignore. On ne rend rien —
            // une sortie tronquée vaut moins qu'un repli propre sur l'étape suivante.
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
            return nil
        }

        lock.lock(); let data = collected; lock.unlock()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Racine Superset

    /// `~/.superset/worktrees`, normalisé une fois. `NSHomeDirectory()` est le vrai `$HOME`
    /// (App Sandbox désactivée — invariant du projet), pas un conteneur.
    private static let supersetWorktreesRoot: URL = URL(
        fileURLWithPath: NSHomeDirectory(), isDirectory: true
    )
    .appendingPathComponent(".superset", isDirectory: true)
    .appendingPathComponent("worktrees", isDirectory: true)
    .standardizedFileURL
}
