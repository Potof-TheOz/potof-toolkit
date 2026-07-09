import Foundation

/// Une session Claude **possédée par l'app** : un process `claude` tournant dans
/// un PTY hébergé par un terminal SwiftTerm embarqué.
///
/// Différence fondamentale avec l'ancien modèle iTerm2 (`ITermSession`) : la
/// session est *possédée* (l'app est le parent du process), donc la fermer **tue**
/// le process. L'état n'est pas persisté : il reflète les process vivants.
struct Session: Identifiable, Hashable {
    let id: UUID
    let folderURL: URL
    /// Titre courant : nom du dossier par défaut, mis à jour par le terminal
    /// (OSC title) si `claude`/le shell en émet un.
    var title: String
    var status: Status

    enum Status: Hashable {
        case running
        case exited(code: Int32?)
    }

    var folderName: String { folderURL.lastPathComponent }

    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
