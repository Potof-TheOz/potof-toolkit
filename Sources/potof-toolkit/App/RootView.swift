import SwiftUI
import Combine

/// Coquille de navigation du toolkit.
///
/// Deux états, et un seul aller possible entre les deux :
/// - `selection == nil` → la **home** (`HomeView`) occupe toute la fenêtre, sans
///   header. C'est l'état de démarrage : au lancement, aucun outil n'est choisi.
/// - `selection != nil` → header (sélecteur d'outil + slot notif) puis l'outil,
///   qui occupe tout le cadre et gère sa propre chrome interne (sidebar, etc.).
///
/// ⚠️ **Aucun chemin ne remet `selection` à `nil`** : la home n'est visible qu'au
/// lancement, on n'y revient pas. Ajouter un « retour à l'accueil » romprait la
/// promesse produit ET détruirait l'outil quitté (`.id(tool.id)` + `@StateObject`,
/// cf. l'invariant des stores app-level dans CLAUDE.md).
///
/// Toujours PAS de `NavigationSplitView` (voir CLAUDE.md) : disposition manuelle,
/// barre supérieure fixe.
struct RootView: View {
    /// `nil` au démarrage = la home. Voir l'aller-simple ci-dessus.
    @State private var selection: Tool.ID?
    /// Coordinateur des notifications Claude (possède le bus + le canal + le Dock).
    /// `let` volontaire : la cloche observe `coordinator.bus` (via `NotificationSlot`),
    /// le switch d'outil passe par `focusRequests` → pas besoin d'observer le
    /// coordinateur lui-même.
    private let coordinator = NotificationCenterCoordinator.shared

    private var selectedTool: Tool? {
        ToolRegistry.all.first { $0.id == selection }
    }

    var body: some View {
        content
            // Clic sur une notif (bannière ou cloche) → basculer sur l'outil concerné.
            // RootView est le seul writer de `selection` (invariant : sélection = header).
            // Reçu depuis la home aussi : une notif cliquée y vaut choix d'outil.
            .onReceive(coordinator.focusRequests) { req in
                selection = req.toolID
            }
    }

    @ViewBuilder
    private var content: some View {
        if let tool = selectedTool {
            VStack(spacing: 0) {
                header(current: tool)
                Divider()
                tool.makeView()
                    .id(tool.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HomeView(tools: ToolRegistry.all) { selection = $0 }
        }
    }

    // MARK: - Header

    /// Le header n'existe qu'avec un outil sélectionné (la home s'affiche sans lui),
    /// d'où l'outil courant passé en paramètre plutôt que relu dans l'état.
    private func header(current tool: Tool) -> some View {
        HStack(spacing: 12) {
            toolSwitcher(current: tool)
            Spacer(minLength: 0)
            NotificationSlot(
                bus: coordinator.bus,
                onReveal: { coordinator.markNotificationsSeen() },
                onSelect: { coordinator.handleClick(sessionID: $0.sessionID) }
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    /// Sélecteur d'outil : menu déroulant listant `ToolRegistry.all`.
    private func toolSwitcher(current: Tool) -> some View {
        Menu {
            ForEach(ToolRegistry.all) { tool in
                Button {
                    selection = tool.id
                } label: {
                    Label(tool.title, systemImage: tool.icon)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current.icon)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(current.title)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Changer d'outil")
        .accessibilityLabel("Outil : \(current.title). Changer d'outil")
    }
}
