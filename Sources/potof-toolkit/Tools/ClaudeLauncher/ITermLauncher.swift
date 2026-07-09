import AppKit

/// Pilote iTerm2 via AppleScript : active l'app, ouvre un nouvel onglet
/// (ou une fenêtre s'il n'y en a aucune), `cd` dans le dossier puis lance `claude`.
enum ITermLauncher {

    static func launch(at path: String) {
        // 1. Échappement shell : le chemin est mis entre apostrophes, donc chaque
        //    apostrophe présente dans le chemin devient la séquence '\'' .
        let shellEscaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "cd '\(shellEscaped)' && claude"

        // 2. Échappement AppleScript : la commande est insérée dans une chaîne
        //    délimitée par des guillemets doubles. On échappe d'abord le backslash,
        //    puis le guillemet double (l'ordre est important).
        let appleScriptEscaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

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
                write text "\(appleScriptEscaped)"
            end tell
        end tell
        """

        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
            if let error = error {
                NSLog("Échec du lancement iTerm2 : \(error)")
            }
        } else {
            NSLog("Impossible de compiler l'AppleScript de lancement.")
        }
    }
}
