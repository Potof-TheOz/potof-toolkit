import Foundation

/// Événement de notification interne — **ancrage (Phase 4)**.
///
/// Destiné à être alimenté plus tard par un canal **local** (socket Unix ou
/// fichier JSONL surveillé) relié au hook `claude-notify.js`, qui taggera chaque
/// event avec le `POTOF_SESSION_ID` de la session émettrice. Rien ne l'alimente
/// pour l'instant : voir `docs/NOTIFICATIONS.md` pour le plan de câblage.
struct AppNotification: Identifiable, Hashable {
    let id: UUID
    /// Session Claude concernée (via `POTOF_SESSION_ID`), si connue.
    let sessionID: UUID?
    let kind: Kind
    let title: String
    let body: String
    let date: Date

    enum Kind: Hashable {
        /// Claude attend une réponse tapée (question de fin de tour, `idle_prompt`…).
        case waiting
        /// L'interface du terminal est **bloquée** en attente d'une action : approbation
        /// d'outil OU choix dans une question interactive (`permission_prompt` — Claude
        /// Code ne distingue pas les deux).
        case permission
        /// Claude a terminé sa tâche (event `Stop`).
        case finished
    }

    var symbol: String {
        switch kind {
        case .waiting: return "bubble.left.fill"
        case .permission: return "bell.badge.fill"
        case .finished: return "checkmark.circle.fill"
        }
    }
}
