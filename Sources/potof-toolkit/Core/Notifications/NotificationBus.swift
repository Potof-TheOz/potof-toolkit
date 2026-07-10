import Foundation
import Combine

/// Bus de notifications interne — **ancrage (Phase 4)**.
///
/// Point d'entrée unique (`ingest`) pour de futurs événements Claude. Le canal de
/// transport (socket Unix / fichier JSONL surveillé + patch de `claude-notify.js`)
/// n'est **pas** branché : voir `docs/NOTIFICATIONS.md`.
///
/// Conçu pour que le branchement futur se résume à : instancier un lecteur de
/// canal qui appelle `ingest(_:)` sur le thread principal.
final class NotificationBus: ObservableObject {
    @Published private(set) var items: [AppNotification] = []

    /// Nombre d'événements non lus (badge du header).
    var count: Int { items.count }

    /// À appeler quand un événement arrive. Aucun émetteur pour l'instant.
    func ingest(_ note: AppNotification) {
        items.insert(note, at: 0)
    }

    func dismiss(_ id: AppNotification.ID) {
        items.removeAll { $0.id == id }
    }

    /// Retire toutes les notifs d'une session (appelé quand on focus son terminal).
    func dismissAll(forSession sessionID: UUID) {
        items.removeAll { $0.sessionID == sessionID }
    }

    func clear() {
        items.removeAll()
    }
}
