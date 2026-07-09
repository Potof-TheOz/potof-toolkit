import Foundation

/// Couture de découplage entre le coordinateur de notifications (niveau app) et
/// l'outil qui possède des sessions Claude.
///
/// L'outil s'y conforme et **s'enregistre** auprès de `NotificationCenterCoordinator` :
/// `Core` n'a ainsi jamais besoin de connaître `SessionStore` ni l'id de l'outil en
/// dur (l'id est fourni à l'enregistrement). Sens de dépendance : **outil → Core**.
protocol NotificationSessionProviding: AnyObject {
    /// La session `id` existe-t-elle (encore) ?
    func containsSession(_ id: UUID) -> Bool
    /// Session actuellement affichée au centre (sert à l'anti-spam).
    var activeSessionID: UUID? { get }
    /// Affiche la session `id` au centre. **No-op si l'id est inconnu**.
    func focusSession(_ id: UUID)
}

/// Demande de focus émise par le coordinateur vers `RootView` : bascule l'outil
/// affiché (`toolID`) et cible la session (`sessionID`).
struct FocusRequest: Equatable {
    let sessionID: UUID
    let toolID: Tool.ID
}
