import AppKit

/// Pilote iTerm2 via AppleScript : lance `claude` dans un nouvel onglet, liste les
/// sessions ouvertes (avec leur répertoire courant) et refocalise un onglet par son id.
enum ITermLauncher {

    private static let bundleID = "com.googlecode.iterm2"

    // MARK: - Lancement

    static func launch(at path: String) {
        // 1. Échappement shell : le chemin est mis entre apostrophes, donc chaque
        //    apostrophe présente dans le chemin devient la séquence '\'' .
        let shellEscaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "cd '\(shellEscaped)' && claude"

        // 2. Échappement AppleScript de la commande à écrire dans le terminal.
        let escapedCommand = appleScriptEscaped(shellCommand)

        let source = """
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window
                    create tab with default profile
                end tell
            end if
            tell current session of current window
                write text "\(escapedCommand)"
            end tell
        end tell
        """

        run(source, context: "lancement")
    }

    // MARK: - Sessions ouvertes

    /// Liste en direct les sessions iTerm2 et leur répertoire courant.
    /// Ne fait rien (et surtout ne démarre pas iTerm2) si l'app n'est pas déjà lancée.
    static func listSessions() -> [ITermSession] {
        guard isRunning else { return [] }

        // Séparateurs de contrôle (unit/record separator) improbables dans un chemin
        // ou un titre de session, pour un découpage sans ambiguïté côté Swift.
        let source = """
        tell application "iTerm2"
            set fs to (character id 31)
            set rs to (character id 30)
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        tell s
                            set sid to id
                            set sname to name
                            set spath to ""
                            try
                                set spath to (variable named "path")
                            end try
                        end tell
                        set out to out & sid & fs & spath & fs & sname & rs
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """

        guard let raw = run(source, context: "listing des sessions")?.stringValue else {
            return []
        }

        return raw
            .components(separatedBy: "\u{1E}")            // record separator
            .compactMap { record -> ITermSession? in
                let fields = record.components(separatedBy: "\u{1F}") // unit separator
                guard fields.count == 3 else { return nil }
                let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let path = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let name = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !path.isEmpty else { return nil }
                return ITermSession(id: id, path: path, name: name)
            }
    }

    /// Refocalise l'onglet iTerm2 correspondant à `sessionId`. Renvoie `false` si aucune
    /// session ne porte cet id (onglet fermé entre-temps).
    @discardableResult
    static func focus(sessionId: String) -> Bool {
        guard isRunning else { return false }

        let escapedID = appleScriptEscaped(sessionId)
        let source = """
        tell application "iTerm2"
            set targetID to "\(escapedID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is targetID then
                            tell s to select
                            tell t to select
                            tell w to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """

        return run(source, context: "focus de session")?.stringValue == "ok"
    }

    // MARK: - Utilitaires

    private static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Échappe une chaîne insérée dans un littéral AppleScript délimité par des guillemets
    /// doubles : on échappe d'abord le backslash, puis le guillemet double (l'ordre importe).
    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func run(_ source: String, context: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            NSLog("Impossible de compiler l'AppleScript (\(context)).")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            NSLog("Échec AppleScript (\(context)) : \(error)")
            return nil
        }
        return result
    }
}
