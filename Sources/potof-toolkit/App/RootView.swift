import SwiftUI

/// Coquille de navigation du toolkit.
///
/// Plus de barre latérale au niveau racine : la **sélection d'outil se fait dans
/// le header** (bouton « Claude Launcher ▾ » ouvrant la liste des outils). En
/// dessous, l'outil sélectionné occupe tout le cadre et gère sa propre chrome
/// interne (sidebar, etc.).
///
/// Toujours PAS de `NavigationSplitView` (voir CLAUDE.md) : disposition manuelle,
/// barre supérieure fixe. Le header réserve aussi la place de la future barre de
/// notif interne (`NotificationSlot`, Phase 4).
struct RootView: View {
    @State private var selection: Tool.ID? = ToolRegistry.all.first?.id
    @StateObject private var notifications = NotificationBus()

    private var selectedTool: Tool? {
        ToolRegistry.all.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            toolSwitcher
            Spacer(minLength: 0)
            NotificationSlot(bus: notifications)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    /// Sélecteur d'outil : menu déroulant listant `ToolRegistry.all`.
    private var toolSwitcher: some View {
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
                if let tool = selectedTool {
                    Image(systemName: tool.icon)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(tool.title)
                        .font(.headline)
                } else {
                    Text("Outils")
                        .font(.headline)
                }
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
        .accessibilityLabel(selectedTool.map { "Outil : \($0.title). Changer d'outil" } ?? "Choisir un outil")
    }

    // MARK: - Détail

    @ViewBuilder
    private var detail: some View {
        if let tool = selectedTool {
            tool.makeView()
                .id(tool.id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Sélectionnez un outil")
                .font(.title3.weight(.semibold))
            Text("Choisissez un outil dans le menu en haut à gauche.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
