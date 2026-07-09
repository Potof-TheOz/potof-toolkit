import SwiftUI

/// Coquille de navigation du toolkit.
///
/// Disposition custom (plutôt que NavigationSplitView) : une barre supérieure
/// fixe contenant le bouton de bascule de la barre latérale — sa position ne
/// dépend donc pas de l'état ouvert/fermé et il ne « saute » jamais. En dessous :
/// barre latérale (liste des outils) + panneau de détail.
struct RootView: View {
    @State private var selection: Tool.ID? = ToolRegistry.all.first?.id
    @State private var sidebarVisible = true

    private var selectedTool: Tool? {
        ToolRegistry.all.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: 244)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Barre supérieure (toggle fixe)

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 15, weight: .medium))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Afficher ou masquer la barre latérale")

            if let tool = selectedTool {
                Divider().frame(height: 16)
                Image(systemName: tool.icon)
                    .foregroundStyle(.tint)
                Text(tool.title)
                    .font(.headline)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.bar)
    }

    // MARK: - Barre latérale

    private var sidebar: some View {
        List(ToolRegistry.all, selection: $selection) { tool in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                    Text(tool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: tool.icon)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.sidebar)
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
            Text("Sélectionnez un outil")
                .font(.title3.weight(.semibold))
            Text("Choisissez un outil dans la barre latérale pour commencer.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
