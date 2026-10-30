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

    static func shellArguments(shell: String, command: String) -> [String] {
        [shell, "-l", "-i", "-c", command]
    }

    /// Le prompt n'est jamais interprété par un shell : il arrive dans `"$@"`.
    static func claudeShellArguments(shell: String, claudeCommand: String,
                                     claudeArguments: [String]) -> [String] {
        [shell, "-l", "-i", "-c", "exec " + shellQuote(claudeCommand) + " \"$@\"", "claude"] + claudeArguments
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

    /// Ajoute en fin de `hooks.Stop` un hook qui pose `stopMarker` ; le reste est intact.
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
