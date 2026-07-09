import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private let appName = "Potof Toolkit"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        setupMainMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        // Hébergement via NSHostingController (recommandé pour intégrer une vue
        // SwiftUI dans une NSWindow créée manuellement).
        window.contentViewController = NSHostingController(rootView: RootView())
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.setFrameAutosaveName("PotofToolkitMainWindow")
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Icône du Dock.
    /// - App bundlée (`.app`) : l'icône provient déjà du `.icns` (Info.plist). On
    ///   n'accède PAS à `Bundle.module` : l'accessor SwiftPM cherche le resource
    ///   bundle à la racine du `.app` (hors structure signable, donc absent) et
    ///   déclencherait un `fatalError` au démarrage.
    /// - Dev (`swift run`, exécutable nu) : on charge `AppIcon.png` depuis le
    ///   resource bundle SPM via `Bundle.module`.
    private func applyDockIcon() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    /// Menu minimal : menu App (À propos / Masquer / Quitter ⌘Q) + menu Édition
    /// pour que ⌘Q et les raccourcis d'édition des champs texte fonctionnent.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Menu application
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "À propos de \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Masquer \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quitter \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Menu Édition (Couper/Copier/Coller dans les champs texte)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Édition")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Tout sélectionner",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        NSApp.mainMenu = mainMenu
    }
}
