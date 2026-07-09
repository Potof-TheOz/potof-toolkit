import SwiftUI
import AppKit
import SwiftTerm

/// Affiche le terminal de la session active. Les `LocalProcessTerminalView` sont
/// possédées par `TerminalController` (jamais recréées) : cette vue ne fait que
/// placer la bonne vue dans un conteneur et lui donner le focus clavier.
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController
    let sessionID: UUID?

    /// Mémorise la dernière session à qui on a donné le focus, pour ne pas le
    /// reprendre à chaque recomposition SwiftUI.
    final class Coordinator {
        var focusedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let desired = sessionID.flatMap { controller.view(for: $0) }

        // Retirer toute vue terminal qui n'est pas celle attendue (on ne la
        // détruit pas : elle reste vivante dans le controller).
        for sub in container.subviews where sub !== desired {
            sub.removeFromSuperview()
        }

        guard let term = desired else {
            context.coordinator.focusedID = nil
            return
        }

        if term.superview !== container {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                term.topAnchor.constraint(equalTo: container.topAnchor),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // Ne donner le focus clavier qu'au **changement** de session affichée.
        // Sinon chaque recomposition (ex. frappe dans le champ de recherche de la
        // sidebar) reprendrait le focus au terminal, rendant la recherche
        // inutilisable.
        if context.coordinator.focusedID != sessionID {
            context.coordinator.focusedID = sessionID
            DispatchQueue.main.async {
                term.window?.makeFirstResponder(term)
            }
        }
    }
}
