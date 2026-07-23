import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private let appName = "Potof Toolkit"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Délai d'apparition des infobulles (`.help`) en millisecondes. Le défaut
        // macOS (~2 s) est jugé trop long. `register` = valeur de repli, ne pollue
        // pas les préférences persistées. Doit être posé avant le 1er survol.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 512])
        applyDockIcon()
        setupMainMenu()

        // Pont IDE : log vierge + nettoyage des locks orphelins (crash précédent).
        IDELog.startSession()
        IDEServer.sweepStaleLocks()

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

        // Branchement des événements Claude : surveille le canal JSONL, alimente la
        // cloche + le Dock, pose les bannières natives. Voir docs/NOTIFICATIONS.md.
        NotificationCenterCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenterCoordinator.shared.stop()
        // SIGKILL explicite des groupes de process des runs de scripts : la
        // fermeture du fd maître du PTY ne SIGHUPe pas un dev server qui
        // l'ignore — sans ça, ports orphelins après quit.
        ScriptTerminalController.shared.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Comme l'app **possède** les process des sessions Claude ET des runs de
    /// scripts (contrairement à l'ancienne intégration iTerm2 où les onglets
    /// survivaient), quitter les tue. On confirme s'il reste des process actifs,
    /// pour éviter de perdre un travail en cours par ⌘Q ou fermeture de fenêtre
    /// réflexe. Sur annulation, on ré-affiche la fenêtre (cas où elle venait
    /// d'être fermée).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let claudeCount = TerminalController.shared.runningProcessCount
        let scriptCount = ScriptTerminalController.shared.runningProcessCount
        guard claudeCount + scriptCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch (claudeCount, scriptCount) {
        case (_, 0):
            // Sessions Claude seulement (libellés historiques conservés).
            alert.messageText = claudeCount == 1
                ? "Une session Claude est active"
                : "\(claudeCount) sessions Claude sont actives"
            alert.informativeText = claudeCount == 1
                ? "Quitter fermera cette session et arrêtera le process Claude."
                : "Quitter fermera ces sessions et arrêtera les process Claude."
        case (0, _):
            // Scripts seulement.
            alert.messageText = scriptCount == 1
                ? "Un script est en cours d'exécution"
                : "\(scriptCount) scripts sont en cours d'exécution"
            alert.informativeText = scriptCount == 1
                ? "Quitter arrêtera ce script (processus tué)."
                : "Quitter arrêtera ces scripts (processus tués)."
        default:
            // Les deux à la fois.
            let sessions = claudeCount == 1
                ? "1 session Claude"
                : "\(claudeCount) sessions Claude"
            let scripts = scriptCount == 1
                ? "1 script"
                : "\(scriptCount) scripts"
            alert.messageText = "Des processus sont actifs : \(sessions) et \(scripts)"
            alert.informativeText = "Quitter fermera "
                + (claudeCount == 1 ? "cette session Claude" : "ces sessions Claude")
                + " et arrêtera "
                + (scriptCount == 1 ? "ce script" : "ces scripts")
                + " (processus tués)."
        }
        alert.addButton(withTitle: "Quitter")
        alert.addButton(withTitle: "Annuler")

        if alert.runModal() == .alertFirstButtonReturn {
            return .terminateNow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return .terminateCancel
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
