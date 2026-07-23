import SwiftUI
import AppKit
import SwiftTerm

/// Affiche un terminal embarqué (SwiftTerm) au centre d'un outil. Vue **partagée**
/// par le Claude Launcher et le Script Runner : les `LocalProcessTerminalView` sont
/// possédées par le contrôleur de l'outil appelant (jamais recréées — sinon perte du
/// process + scrollback) ; cette vue ne fait que **placer** la vue résolue par
/// l'appelant dans un conteneur et lui donner le focus clavier.
struct TerminalHostView: NSViewRepresentable {
    /// Vue terminal résolue par l'appelant (gardée vivante ailleurs, dans le
    /// contrôleur propriétaire). `nil` ⇒ rien à afficher.
    let terminal: LocalProcessTerminalView?
    /// Identité de ce qui est affiché (session, run…) : le focus clavier n'est
    /// donné qu'au **changement** de cette identité.
    let focusID: UUID?

    /// Mémorise la dernière identité à qui on a donné le focus, pour ne pas le
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
        // Retirer toute vue terminal qui n'est pas celle attendue (on ne la
        // détruit pas : elle reste vivante dans son contrôleur).
        for sub in container.subviews where sub !== terminal {
            sub.removeFromSuperview()
        }

        guard let term = terminal else {
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

        // Ne donner le focus clavier qu'au **changement** d'identité affichée.
        // Sinon chaque recomposition (ex. frappe dans le champ de recherche de la
        // sidebar) reprendrait le focus au terminal, rendant la recherche
        // inutilisable.
        if context.coordinator.focusedID != focusID {
            context.coordinator.focusedID = focusID
            DispatchQueue.main.async {
                term.window?.makeFirstResponder(term)
            }
        }
    }
}
