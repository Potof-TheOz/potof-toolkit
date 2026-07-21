import Foundation

/// Petit enrobage synchrone autour de `git` lancé via `Foundation.Process`.
///
/// Choix volontaires (cf. CLAUDE.md : aucune dépendance, sandbox désactivée) :
/// - **Aucune lib git** : tout passe par un shell-out vers le binaire système.
/// - **Chemin absolu `/usr/bin/git`** : dans une app lancée depuis le Finder, le
///   PATH n'est pas celui d'un shell de login (pas de Homebrew…). `/usr/bin/git`
///   est le shim standard des *Command Line Tools* de macOS, toujours présent sur
///   un poste de dev. On l'utilise aussi dans les `exec` du todo de rebase.
/// - **Bloquant** : `run` attend la fin du process. Les appelants l'invoquent donc
///   depuis une file de fond et republient sur le thread principal.
enum Git {
    /// Binaire `git` utilisé pour toutes les commandes (et les `exec` du rebase).
    static let executablePath = "/usr/bin/git"

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

    /// Exécute `git <args>` dans `directory`. `extraEnvironment` complète (et écrase)
    /// l'environnement du process courant. **Bloquant** : à appeler hors thread principal.
    @discardableResult
    static func run(
        _ args: [String],
        in directory: URL,
        extraEnvironment: [String: String] = [:]
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.currentDirectoryURL = directory

        var env = ProcessInfo.processInfo.environment
        // Garantit que `git` (et les `exec` du rebase) trouvent `git`, `cat`, `sh`…
        // même si l'app est lancée avec un PATH minimal.
        let path = env["PATH"] ?? ""
        if !path.contains("/usr/bin") {
            env["PATH"] = path.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : "/usr/bin:/bin:/usr/sbin:/sbin:\(path)"
        }
        // Jamais de prompt interactif bloquant (identifiants, etc.).
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Result(code: -1, stdout: "", stderr: "Impossible de lancer git : \(error.localizedDescription)")
        }

        // Lecture AVANT waitUntilExit pour éviter un blocage si un pipe se remplit.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            code: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Échappe une chaîne pour l'insérer entre apostrophes dans une commande shell
    /// (`'` → `'\''`). Même technique que le `cd '<dossier>'` du Claude Launcher.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Traduit une sortie `git status --porcelain` en lignes lisibles
    /// (`(label français, chemin)`), pour dire **précisément** ce qui salit l'arbre.
    /// Format porcelain v1 : deux caractères d'état `XY` (X = indexé, Y = copie de
    /// travail) puis un espace et le chemin (les renommages sont `orig -> dest`).
    static func describeStatus(_ porcelain: String) -> [(label: String, path: String)] {
        porcelain.split(separator: "\n").compactMap { raw -> (String, String)? in
            let line = String(raw)
            guard line.count >= 4 else { return nil }
            let chars = Array(line)
            let x = chars[0], y = chars[1]
            let path = String(line.dropFirst(3))

            let label: String
            if x == "?" && y == "?" {
                label = "Non suivi"
            } else if x == "!" && y == "!" {
                label = "Ignoré"
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                label = "Conflit (non fusionné)"
            } else {
                var parts: [String] = []
                switch x {          // changements indexés (staged)
                case "M": parts.append("modifié (indexé)")
                case "A": parts.append("ajouté (indexé)")
                case "D": parts.append("supprimé (indexé)")
                case "R": parts.append("renommé (indexé)")
                case "C": parts.append("copié (indexé)")
                default: break
                }
                switch y {          // changements dans la copie de travail
                case "M": parts.append("modifié")
                case "D": parts.append("supprimé")
                default: break
                }
                label = parts.isEmpty ? "\(x)\(y)" : parts.joined(separator: " + ")
            }
            return (label, path)
        }
    }

    /// Nettoie une sortie git destinée à être **affichée** (pas parsée) : retire les
    /// séquences d'échappement ANSI et les retours chariot du méter de progression.
    /// git n'en émet normalement pas hors TTY (nos pipes), mais c'est une assurance.
    static func sanitize(_ text: String) -> String {
        let noAnsi = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        return noAnsi.replacingOccurrences(of: "\r", with: "")
    }
}
