import AppKit
import SwiftUI

/// **Point d'entrée UI de l'hôte IDE** : le menu « Hôte IDE » de la barre de menus, et
/// la fenêtre de diagnostic qu'il ouvre.
///
/// Pourquoi la barre de menus plutôt qu'un onglet d'outil : l'hôte n'appartient à aucun
/// outil (il sert des agents **externes** à l'app), et le réglage doit rester joignable
/// même quand la fenêtre principale est fermée ou qu'on est dans un autre outil. Un menu
/// est aussi le bon endroit pour un choix exclusif à trois valeurs — coché, pas de
/// formulaire.
///
/// Singleton : il retient la fenêtre de diagnostic (une seule, ré-affichée telle quelle)
/// et sert de `target` aux items de menu. Tout se passe sur le thread principal (AppKit
/// n'appelle les actions de menu que là).
final class IDEHostMenu: NSObject, NSMenuDelegate {

    static let shared = IDEHostMenu()

    /// Fenêtre de diagnostic, gardée allouée entre deux ouvertures (`isReleasedWhenClosed
    /// = false`) : sa vue SwiftUI et son cadre sont conservés, la ré-afficher est
    /// instantané.
    private var statusWindow: NSWindow?

    /// Items dont l'état (coche) est recalculé à chaque ouverture du menu.
    private var scopeItems: [NSMenuItem] = []
    private weak var activateItem: NSMenuItem?

    private override init() { super.init() }

    /// Construit l'item racine à insérer dans `NSApp.mainMenu`.
    ///
    /// Le titre affiché dans la barre est celui du **sous-menu** (convention AppKit),
    /// d'où le `NSMenu(title:)`.
    func makeMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Hôte IDE")
        menu.delegate = self            // → `menuNeedsUpdate` recalcule les coches
        menu.autoenablesItems = false   // sinon AppKit désactiverait tout (pas de responder)
        root.submenu = menu

        let title = NSMenuItem(title: "Servir les agents Claude de :", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        for scope in IDEHostScope.allCases {
            let item = NSMenuItem(title: scope.title,
                                  action: #selector(selectScope(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = scope
            item.indentationLevel = 1
            item.toolTip = scope.detail
            menu.addItem(item)
            scopeItems.append(item)
        }

        menu.addItem(.separator())

        let activate = NSMenuItem(title: "Activer l'app à la réception d'une demande",
                                  action: #selector(toggleActivateOnRequest(_:)),
                                  keyEquivalent: "")
        activate.target = self
        activate.toolTip = "Décoché (défaut) : la fenêtre de revue apparaît sans voler le "
            + "focus clavier. Coché : l'app passe au premier plan."
        menu.addItem(activate)
        activateItem = activate

        menu.addItem(.separator())

        let status = NSMenuItem(title: "Clients connectés…",
                                action: #selector(showStatusWindow(_:)),
                                keyEquivalent: "")
        status.target = self
        status.toolTip = "Port, périmètre et agents `claude` actuellement connectés."
        menu.addItem(status)

        return root
    }

    // MARK: - NSMenuDelegate

    /// Les coches sont recalculées à l'ouverture (et pas maintenues à jour en continu) :
    /// le réglage peut changer ailleurs (panneau, `defaults write`), et un menu fermé n'a
    /// aucune raison d'être synchronisé.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = IDEHostSettings.shared
        for item in scopeItems {
            let scope = item.representedObject as? IDEHostScope
            item.state = (scope == settings.scope) ? .on : .off
        }
        activateItem?.state = settings.activateAppOnRequest ? .on : .off
    }

    // MARK: - Actions

    /// Change le périmètre. L'application à chaud (republication du lock, arrêt ou
    /// redémarrage de l'hôte) est faite par le `didSet` de `IDEHostSettings.scope` →
    /// `IDEHost.applyCurrentScope()` : rien à orchestrer ici.
    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let scope = sender.representedObject as? IDEHostScope else { return }
        IDEHostSettings.shared.scope = scope
    }

    @objc private func toggleActivateOnRequest(_ sender: NSMenuItem) {
        IDEHostSettings.shared.activateAppOnRequest.toggle()
    }

    @objc private func showStatusWindow(_ sender: Any?) {
        let window = statusWindow ?? makeStatusWindow()
        statusWindow = window
        // Geste explicite de l'utilisateur : ici, prendre le focus est exactement ce
        // qu'il demande (contrairement à la fenêtre de revue, qui, elle, s'ouvre sur
        // l'initiative d'un agent).
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeStatusWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Hôte IDE"
        // `NSHostingController` et **jamais** `NSHostingView` (invariant du projet) :
        // c'est ce qui donne l'intégration titlebar correcte en hébergement manuel.
        window.contentViewController = NSHostingController(rootView: IDEHostStatusView())
        window.setContentSize(NSSize(width: 520, height: 420))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PotofIDEHostStatusWindow")
        window.center()
        return window
    }
}
