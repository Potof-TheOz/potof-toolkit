import Foundation

/// Registre central des outils du toolkit.
///
/// 👉 Point d'extension unique : ajouter une entrée `Tool(...)` ci-dessous
///    suffit à faire apparaître un nouvel outil dans la barre latérale.
enum ToolRegistry {
    static let all: [Tool] = [
        Tool(
            id: "claude-launcher",
            title: "Claude Launcher",
            subtitle: "Lancer Claude Code dans un dossier via iTerm2",
            icon: "terminal.fill",
            view: { ClaudeLauncherView() }
        )
    ]
}
