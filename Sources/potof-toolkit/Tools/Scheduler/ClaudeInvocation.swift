import Foundation

/// Construction pure de l'invocation de `claude` pour un run planifié : argv, environnement,
/// settings du run, confiance du dossier. Aucun process, aucun écrit — testé par
/// `--sched-selftest claude`.
enum ClaudeInvocation {

    struct SettingsError: Error, CustomStringConvertible {
        let description: String
    }

    /// `$SHELL` si son nom est zsh, bash ou sh ; sinon `/bin/zsh`.
    static func shell(from environment: [String: String]) -> String {
        if let shell = environment["SHELL"],
           ["zsh", "bash", "sh"].contains((shell as NSString).lastPathComponent) {
            return shell
        }
        return "/bin/zsh"
    }

    /// `-l -i` : sourcing des rc (PATH complet). Mais un shell interactif active le contrôle
    /// de jobs : chaque commande du préscript, chaque job de fond et chaque pipeline
    /// (`claude mcp list | cat`) partirait dans son **propre groupe**, hors d'atteinte de
    /// `kill(-pid, …)` — un `npm run dev &` survivrait au délai. On le coupe donc :
    /// `+m` à l'invocation (suffit à zsh) ET `set +m;` en tête de commande (bash et sh
    /// ignorent `+m` quand `-i` est présent — mesuré avec bash 3.2 ; c'est aussi
    /// la forme qu'une rc ne peut pas défaire). Tout reste alors dans le groupe du shell.
    static func shellArguments(shell: String, command: String) -> [String] {
        [shell, "-l", "-i", "+m", "-c", "set +m; " + command]
    }

    /// Même `+m` par cohérence ; le `set +m;` est inutile ici : `exec` fait de `claude`
    /// le chef de session, il n'y a pas de job à rattraper.
    ///
    /// Le prompt n'est jamais interprété par un shell : il arrive dans `"$@"`.
    static func claudeShellArguments(shell: String, claudeCommand: String,
                                     claudeArguments: [String]) -> [String] {
        [shell, "-l", "-i", "+m", "-c", "exec " + shellQuote(claudeCommand) + " \"$@\"", "claude"] + claudeArguments
    }

    /// `--permission-mode dontAsk` est imposé ; le prompt vient après `--`.
    static func claudeArguments(prompt: String, sessionID: UUID, settingsFile: URL,
                                model: String?, effort: String?) -> [String] {
        var args = ["--session-id", sessionID.uuidString.lowercased(),
                    "--permission-mode", "dontAsk",
                    "--settings", settingsFile.path]
        if let model = model { args += ["--model", model] }
        if let effort = effort { args += ["--effort", effort] }
        return args + ["--", prompt]
    }

    static func environment(base: [String: String]) -> [String] {
        var env = base.filter { key, _ in
            key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_") && key != "POTOF_SESSION_ID"
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "false"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// Ajoute en fin de `hooks.Stop` un hook qui pose `stopMarker`, et impose `"tui": "default"`.
    /// Le reste est intact.
    ///
    /// ⚠️ `tui` est imposé même si le fichier de l'utilisateur dit autre chose : en `fullscreen`,
    /// `claude` dessine sur l'écran ALTERNATIF (`ESC[?1049h`) et le quitte à `/exit`. Le rejeu
    /// d'un run terminé ne montrait alors que « Resume this session with… » (mesuré le
    /// 2026-10-30, `claude` 2.1.314). Le rendu classique écrit dans l'écran principal, donc
    /// tout le déroulé reste dans le `.tty`.
    static func runSettings(userSettings: Data?, stopMarker: URL) throws -> Data {
        var root: [String: Any] = [:]
        if let data = userSettings {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw SettingsError(description: "le fichier de settings n'est pas un objet JSON")
            }
            root = object
        }
        var hooks: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let dict = existing as? [String: Any] else {
                throw SettingsError(description: "`hooks` n'est pas un objet")
            }
            hooks = dict
        }
        var stop: [Any] = []
        if let existing = hooks["Stop"] {
            guard let array = existing as? [Any] else {
                throw SettingsError(description: "`hooks.Stop` n'est pas un tableau")
            }
            stop = array
        }
        stop.append(["hooks": [["type": "command", "command": "touch " + shellQuote(stopMarker.path)]]])
        hooks["Stop"] = stop
        root["hooks"] = hooks
        root["tui"] = "default"
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// `hasTrustDialogAccepted == true` pour ce dossier précisément ; les parents ne comptent pas.
    static func isTrusted(folderPath: String, claudeJSON: Data?) -> Bool {
        guard let data = claudeJSON,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return false }
        let target = normalized(folderPath)
        for (key, value) in projects where normalized(key) == target {
            if (value as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return true }
        }
        return false
    }

    static var claudeJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// `'…'` avec `'` → `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }
}
