import Foundation
import Combine

/// Source de vérité des sessions Claude embarquées pour la couche SwiftUI.
/// Possède le `TerminalController` qui gère les vues/process AppKit.
///
/// Non annoté `@MainActor` volontairement (le projet n'utilise aucune annotation
/// de concurrence) : par construction, toutes les mutations passent par le thread
/// principal — actions UI + callbacks du controller déjà remarshalés sur `main`.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var activeID: UUID?

    let terminal = TerminalController.shared

    init() {
        terminal.onTitleChange = { [weak self] id, title in
            self?.updateTitle(id, title)
        }
        terminal.onProcessExit = { [weak self] id, code in
            self?.handleExit(id, code)
        }
    }

    var activeSession: Session? { sessions.first { $0.id == activeID } }

    /// Chemins normalisés des dossiers ayant au moins une session en cours.
    var runningFolderPaths: Set<String> {
        Set(sessions.map { Self.normalized($0.folderURL.path) })
    }

    // MARK: - Actions

    /// Lance une nouvelle session dans `folder` et l'active.
    func launch(folder: URL) {
        let id = UUID()
        sessions.append(
            Session(id: id, folderURL: folder, title: folder.lastPathComponent, status: .running)
        )
        terminal.start(id: id, folder: folder)
        activeID = id
    }

    /// Ferme une session : **tue le process** puis retire l'entrée.
    func close(_ id: UUID) {
        terminal.terminate(id: id)
        remove(id)
    }

    func focus(_ id: UUID) { activeID = id }

    // MARK: - Privé

    private func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if activeID == id { activeID = sessions.last?.id }
    }

    private func updateTitle(_ id: UUID, _ title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        // On ne remplace pas par un titre vide ; sinon on garde le nom du dossier.
        sessions[i].title = title
    }

    /// Le process s'est terminé de lui-même (`claude` a quitté) → on libère la vue
    /// et on retire la session (fidèle à l'esprit « pas de session fantôme »).
    private func handleExit(_ id: UUID, _ code: Int32?) {
        terminal.terminate(id: id)
        remove(id)
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
