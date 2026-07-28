import AppKit
import Combine
import SwiftUI
import UserNotifications

/// **Fenêtre flottante de revue des diffs.**
///
/// Surface unique de validation, volontairement **indépendante de l'outil affiché**
/// dans la fenêtre principale : une demande arrive pendant qu'on est dans Git Stuffs,
/// elle doit être visible sans changer d'outil ni voler le focus (un agent bloque en
/// attendant, mais l'utilisateur est peut-être en train de taper ailleurs).
///
/// Choix imposés :
/// - `NSPanel` `isFloatingPanel` / `level = .floating` /
///   `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` /
///   `hidesOnDeactivate = false` → visible par-dessus Superset, sur tous les espaces ;
/// - `contentViewController = NSHostingController` (**invariant du projet** : jamais
///   `NSHostingView` pour héberger du SwiftUI dans une fenêtre créée à la main) ;
/// - apparition via `orderFrontRegardless()` : ne vole pas le focus clavier.
///
/// Contrôleur AppKit (pas une vue) : la fenêtre survit au cycle de vie des vues.
/// Singleton app-level pour la même raison que `SessionStore.shared` — son contenu
/// est adossé à des connexions vivantes, il ne doit pas mourir avec une vue.
///
/// **Thread** : tout ici est du thread principal (AppKit). Les seules entrées sont
/// l'abonnement au centre (qui ne mute que sur le thread principal) et le clic de
/// bannière (remarshalé par `NotificationCenterCoordinator`).
final class DiffReviewWindowController: NSObject, NSWindowDelegate {

    static let shared = DiffReviewWindowController()

    // MARK: - Réglages de la fenêtre

    /// Clé d'autosave AppKit : position **et** taille sont mémorisées dans les
    /// `UserDefaults` du domaine de l'app (clé « NSWindow Frame … »). Le cadre est
    /// donc conservé entre deux apparitions *et* entre deux lancements — un panneau
    /// qui se recentrerait à chaque diff serait insupportable, d'autant qu'il en
    /// arrive plusieurs par minute quand plusieurs agents tournent.
    private static let frameAutosaveName = "PotofDiffReviewPanel"
    /// Confortable pour un diff (assez large pour la vue côte à côte de T5) sans
    /// occuper tout l'écran : le panneau se superpose au travail en cours.
    private static let defaultSize = NSSize(width: 980, height: 720)
    /// En dessous, un diff n'est plus lisible : on empêche de réduire par accident.
    private static let minSize = NSSize(width: 640, height: 420)

    /// Clé posée dans le `userInfo` de nos bannières. `NotificationCenterCoordinator`
    /// est le délégué **unique** d'`UNUserNotificationCenter` pour toute l'app : c'est
    /// à ce marqueur qu'il distingue nos bannières de celles des sessions Claude, pour
    /// router le clic vers `bringToFront()` au lieu du focus d'une session.
    static let bannerUserInfoKey = "diffReviewID"
    /// Regroupe nos bannières entre elles dans le centre de notifications.
    private static let bannerThread = "potof.diff-review"

    // MARK: - État

    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private var started = false

    /// Identifiants des demandes déjà vues. Permet de distinguer, à chaque émission
    /// du centre, les **arrivées** (→ remonter le panneau, poser une bannière) des
    /// **départs** (→ retirer la bannière déjà livrée, devenue sans cible).
    private var knownIDs: Set<UUID> = []

    /// Même garde que `NotificationCenterCoordinator` et `AppDelegate.applyDockIcon` :
    /// `UNUserNotificationCenter.current()` lit `bundleProxyForCurrentProcess` et
    /// **crashe** sous `swift run` (exécutable nu, aucun bundle). En dev on se contente
    /// donc du panneau + de la pastille du Dock ; les bannières se testent sur l'app
    /// bundlée. L'autorisation, elle, est demandée une fois par le coordinateur.
    private let canUseUN = Bundle.main.bundleURL.pathExtension == "app"

    private override init() { super.init() }

    // MARK: - Cycle de vie

    /// Branche le contrôleur sur `DiffReviewCenter` : ouvre le panneau à la première
    /// demande, le referme quand la file se vide. Appelé une fois au démarrage.
    /// Idempotent : un second appel (depuis un autre point d'amorçage) est sans effet.
    func start() {
        guard !started else { return }
        started = true
        // On s'abonne à `$pending` plutôt qu'à `objectWillChange` pour recevoir la
        // **nouvelle** valeur en argument : `@Published` émet en `willSet`, relire
        // `DiffReviewCenter.shared.pending` dans le callback renverrait l'ancienne.
        subscription = DiffReviewCenter.shared.$pending.sink { [weak self] pending in
            // Remarshalage systématique, même si on est déjà sur le thread principal
            // (c'est le cas) : l'émission a lieu AVANT que le tableau ne soit affecté.
            // Construire le `NSHostingController` ici ferait lire à SwiftUI l'état
            // d'AVANT la mutation, et sa souscription s'installerait après
            // l'`objectWillChange` déjà parti → un panneau qui s'ouvre vide et ne se
            // rafraîchit jamais.
            DispatchQueue.main.async { self?.queueDidChange(pending) }
        }
    }

    /// Affiche le panneau (sans prendre le focus) et le place au premier plan.
    func present() {
        let panel = makePanelIfNeeded()
        // ⚠️ `orderFrontRegardless()` et **pas** `makeKeyAndOrderFront(_:)` : la
        // demande vient d'un agent EXTERNE (Superset, un terminal du poste), donc
        // l'app est le plus souvent en arrière-plan et l'utilisateur en train de
        // taper ailleurs. Prendre le focus clavier à cet instant lui volerait des
        // frappes. `orderFront(_:)` seul ne suffirait pas : AppKit l'ignore quand
        // l'app n'est pas active — d'où la variante `Regardless`.
        //
        // Le panneau reste malgré tout capable de devenir key (`.titled` +
        // `becomesKeyOnlyIfNeeded = false`) : un simple clic dedans l'active et les
        // raccourcis Échap / ⌘⏎ de `DiffReviewView` fonctionnent alors. Le focus est
        // pris sur geste explicite de l'utilisateur, jamais imposé (cf. `bringToFront`).
        //
        // Sauf demande explicite : le réglage « Activer l'app à la réception »
        // (`ideHost.activateOnRequest`, désactivé par défaut) inverse ce compromis pour
        // qui préfère être interrompu — un agent bloqué sur un `openDiff` attend
        // indéfiniment, et certains veulent le voir tout de suite plutôt que de
        // découvrir la pastille du Dock dix minutes plus tard.
        if IDEHostSettings.shared.activateAppOnRequest {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Masque le panneau (la file est vide, ou l'utilisateur l'a fermé).
    func hide() {
        // `orderOut` et pas `close()` : la fenêtre reste allouée avec son contenu
        // SwiftUI et son cadre courant → la ré-afficher est instantané et ne
        // reconstruit pas la vue.
        panel?.orderOut(nil)
    }

    /// Remonte le panneau **avec** le focus clavier. Réservé aux gestes **explicites**
    /// de l'utilisateur (clic sur une bannière) : là, il demande à venir voir, donc
    /// activer l'app et rendre le panneau key est exactement ce qu'il attend.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // Rien en attente (demande résolue entre-temps, ou fermée par `close_tab`) :
        // pas de panneau vide à imposer, l'activation de l'app suffit.
        guard !DiffReviewCenter.shared.pending.isEmpty else { return }
        makePanelIfNeeded().makeKeyAndOrderFront(nil)
    }

    // MARK: - Réaction à la file

    private func queueDidChange(_ pending: [PendingDiffReview]) {
        let ids = Set(pending.map(\.id))
        let arrivals = pending.filter { !knownIDs.contains($0.id) }
        let departures = knownIDs.subtracting(ids)
        knownIDs = ids

        // Une demande résolue ne doit plus traîner dans le centre de notifications :
        // sa bannière n'a plus de cible, et cliquer dessus rouvrirait un panneau
        // parlant d'un diff déjà tranché.
        if !departures.isEmpty, canUseUN {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: departures.map(\.uuidString))
        }

        if !arrivals.isEmpty {
            // Remonter à **chaque** arrivée, pas seulement sur la transition 0 → 1 :
            // l'utilisateur a pu fermer le panneau à la main alors qu'il restait des
            // demandes, et une nouvelle arrivée = un agent de plus bloqué en attente.
            present()
            for item in arrivals { signalIfBackgrounded(item, queueSize: pending.count) }
        }

        // File vide → plus rien à valider : le panneau disparaît de lui-même. C'est
        // le seul cas de fermeture automatique (une demande retirée sans décision
        // part en `.rejected` côté centre, l'agent n'est donc jamais laissé en plan).
        if pending.isEmpty { hide() }
    }

    // MARK: - Le panneau

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        // Création **paresseuse** : au lancement, rien ne justifie de monter une vue
        // SwiftUI pour une file vide. Une seule instance ensuite, gardée pour toute la
        // vie de l'app (elle n'a rien à voir avec le registre d'outils : changer
        // d'outil détruit les vues de `RootView`, jamais cette fenêtre).
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)

        p.title = "Modifications à valider"
        // Panneau utilitaire flottant : reste au-dessus des fenêtres de l'app…
        p.isFloatingPanel = true
        // …et au-dessus des autres apps (Superset, terminal) : la demande bloque un
        // agent, elle ne doit pas se retrouver enterrée sous la fenêtre où l'on tape.
        p.level = .floating
        // `.canJoinAllSpaces` : suit l'utilisateur d'un espace à l'autre — répondre à
        // un diff ne doit jamais imposer un changement d'espace (l'animation ferait
        // perdre le contexte). `.fullScreenAuxiliary` : s'affiche par-dessus une app
        // en plein écran, cas courant pour Superset.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Un panneau se cache par défaut quand l'app perd le focus : ce serait
        // exactement le contraire du besoin (l'utilisateur travaille dans Superset et
        // doit voir la demande arriver).
        p.hidesOnDeactivate = false
        // Le panneau doit pouvoir devenir key au premier clic : les raccourcis
        // Échap (Refuser) / ⌘⏎ (Accepter) de la vue en dépendent, tout comme
        // l'éditeur libre de T6. `true` réserverait le focus aux seuls champs texte.
        p.becomesKeyOnlyIfNeeded = false
        // ⚠️ Indispensable : par défaut AppKit **libère** une fenêtre à sa fermeture.
        // Sans ça, la croix du titre détruirait l'objet et la demande suivante
        // toucherait un pointeur mort (`panel` non-nil mais libéré).
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow

        // **Invariant du projet** : `NSHostingController`, jamais `NSHostingView`,
        // pour héberger du SwiftUI dans une fenêtre créée à la main (intégration
        // correcte titlebar/toolbar, cycle de vie de la vue géré par AppKit).
        // `DiffReviewView` observe `DiffReviewCenter.shared` : la vue est construite
        // une fois pour toutes, c'est la file qui change sous elle.
        p.contentViewController = NSHostingController(rootView: DiffReviewView())
        p.contentMinSize = Self.minSize
        p.setContentSize(Self.defaultSize)

        // Restauration du cadre mémorisé (position + taille) ; premier lancement →
        // centrage. `setFrameUsingName` doit précéder `setFrameAutosaveName`, qui se
        // contente d'armer la sauvegarde automatique des déplacements suivants.
        if !p.setFrameUsingName(Self.frameAutosaveName) { p.center() }
        p.setFrameAutosaveName(Self.frameAutosaveName)

        p.delegate = self
        panel = p
        IDELog.log("revue : panneau flottant créé")
        return p
    }

    // MARK: - NSWindowDelegate

    /// Fermeture manuelle (croix du titre) alors que des demandes restent en attente :
    /// on n'en profite **pas** pour refuser à la place de l'utilisateur — un agent
    /// bloqué le reste, c'est son droit de trancher plus tard. Le panneau est
    /// seulement masqué ; la pastille du Dock (composée dans
    /// `NotificationCenterCoordinator`) continue d'afficher le nombre de demandes, et
    /// la prochaine arrivée — ou un clic sur une bannière — le fait revenir.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let remaining = DiffReviewCenter.shared.pending.count
        if remaining > 0 {
            IDELog.log("revue : panneau fermé à la main, \(remaining) demande(s) toujours en attente")
        }
        return true
    }

    // MARK: - Signalement en arrière-plan

    /// Bannière macOS native pour une demande qui arrive alors que l'app **n'est pas**
    /// au premier plan : sans elle, la demande d'un agent externe pourrait rester
    /// invisible derrière la fenêtre de Superset, agent bloqué compris.
    private func signalIfBackgrounded(_ item: PendingDiffReview, queueSize: Int) {
        // App déjà active : le panneau vient d'apparaître sous les yeux de
        // l'utilisateur, une bannière par-dessus ne serait que du bruit.
        guard !NSApp.isActive else { return }
        // ⚠️ Voir `canUseUN` : sous `swift run`, toucher `UNUserNotificationCenter`
        // crashe. L'autorisation a été demandée par `NotificationCenterCoordinator`
        // au démarrage (une seule demande pour toute l'app).
        guard canUseUN else { return }

        let file = URL(fileURLWithPath: item.request.oldPath).lastPathComponent
        let content = UNMutableNotificationContent()
        content.title = "✎ Modification à valider — \(item.origin.label)"
        var body = item.diff.isNewFile
            ? "\(file) · nouveau fichier (+\(item.diff.addedCount))"
            : "\(file) · +\(item.diff.addedCount)/−\(item.diff.removedCount)"
        if queueSize > 1 { body += " — \(queueSize) en attente" }
        content.body = body
        content.sound = .default
        content.threadIdentifier = Self.bannerThread
        content.userInfo = [Self.bannerUserInfoKey: item.id.uuidString]

        // Identifiant = celui de la demande → on saura retirer précisément cette
        // bannière quand la demande sera résolue (cf. `queueDidChange`).
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }
}
