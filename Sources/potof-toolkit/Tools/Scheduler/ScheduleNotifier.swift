import Foundation
import UserNotifications

/// Bannière système d'un run planifié.
///
/// ## Pourquoi ce fichier existe séparément
/// `ScheduleRunner` n'importe que `Foundation` — c'est une garantie **structurelle** :
/// avec ce seul import, `NSApp` est une erreur de compilation, donc le mode headless ne
/// peut pas réveiller un singleton de la GUI. On isole donc ici le seul framework
/// supplémentaire dont on a besoin. ⚠️ `UserNotifications` n'est **ni AppKit ni SwiftUI** :
/// l'importer n'ouvre pas la porte à `NSApp`, et la garantie tient toujours.
///
/// ## Pourquoi pas `osascript`
/// C'était l'implémentation initiale, calquée sur les scripts bash du poste. **Mesuré :
/// elle ne délivre rien.** Quatre runs `launchd` conclus en `skipped` ont appelé
/// `/usr/bin/osascript` avec un code de sortie 0, sans qu'aucune bannière n'apparaisse —
/// et « Script Editor » n'apparaît même pas dans les réglages de notification du poste.
/// Un `display notification` émis par le binaire `osascript` n'a pas d'identité d'app
/// enregistrée, et macOS le jette en silence. Un `exit 0` ne prouvait donc rien.
///
/// L'identité correcte était disponible depuis le début : l'app **est** enregistrée
/// (`com.potof.potof-toolkit`), puisqu'elle pose déjà des bannières pour les sessions
/// Claude. Sous launchd, le runner s'exécute depuis `…/Potof Toolkit.app/Contents/MacOS/`,
/// il porte donc ce bundle — et cette identité-là, le Centre de notifications la connaît.
enum ScheduleNotifier {

    /// **Même garde que `canUseUN`** (`NotificationCenterCoordinator`, `DiffReviewWindow`) :
    /// `UNUserNotificationCenter` exige un vrai bundle. En `swift run` le binaire est nu et
    /// l'appel **plante**. Sous launchd il est bundlé, donc la garde passe.
    static var canPost: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Poste la bannière et **attend** sa remise.
    ///
    /// L'attente n'est pas un confort : le process headless meurt dès le `exit(...)` du
    /// runner, et une notification encore en vol serait perdue. Le délai est court et
    /// borné — un canal de notification ne doit jamais retarder un job.
    ///
    /// Renvoie une phrase pour le journal du run : c'est le seul moyen de savoir, après
    /// coup, pourquoi une bannière n'est pas arrivée.
    @discardableResult
    static func post(title: String, subtitle: String, body: String,
                     timeout: TimeInterval = 5) -> String {
        guard canPost else {
            return "bannière ignorée : binaire non bundlé (développement)"
        }

        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)
        // Verrouillée, et pas un simple `var` capturé : sur le chemin du délai dépassé, le
        // callback du Centre de notifications peut écrire à l'instant même où l'appelant
        // renonce et relit. Même idiome que `SupersetCLI.Flag` / `OutputBox`.
        let outcome = Outcome("bannière : aucune réponse du Centre de notifications")

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                outcome.set("bannière refusée : \(error.localizedDescription)")
                semaphore.signal()
                return
            }
            guard granted else {
                // Cas réel à ne pas masquer : l'utilisateur a refusé les notifications de
                // l'app. Le run, lui, s'est parfaitement déroulé.
                outcome.set("bannière non autorisée pour Potof Toolkit")
                semaphore.signal()
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default

            // `trigger: nil` = remise immédiate.
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request) { addError in
                outcome.set(addError.map { "bannière en échec : \($0.localizedDescription)" }
                    ?? "bannière remise")
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            outcome.set("bannière : délai dépassé (\(Int(timeout)) s)")
        }
        return outcome.value
    }

    /// Boîte verrouillée : l'issue est écrite par les callbacks du Centre de notifications
    /// et relue par l'appelant, qui a pu renoncer sur délai au même instant.
    private final class Outcome {
        private let lock = NSLock()
        private var text: String
        init(_ initial: String) { text = initial }
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}
