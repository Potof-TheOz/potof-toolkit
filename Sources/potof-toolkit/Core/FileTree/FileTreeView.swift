import SwiftUI

/// Vue **générique** d'arborescence de fichiers, réutilisable partout (liste des
/// modifications git, fichiers d'un commit…). Elle possède la chrome (indentation, chevrons,
/// icône dossier, pliage, surlignage de sélection, survol) ; l'appelant injecte le contenu :
///
/// - `onSelect(value)` — clic sur un **fichier** ;
/// - `leading(value)` — badge/icône du fichier (toujours visible) ;
/// - `trailing(value)` — actions du fichier (**révélées au survol** de la ligne, mais
///   présentes dans l'arbre → accessibilité préservée) ;
/// - `folderTrailing(path, feuillesDuSousArbre)` — actions au niveau **dossier** (au survol).
///
/// Pliage : **tout déplié** par défaut, mémorisé par chemin tant que la vue vit. Clic sur un
/// dossier = plier/déplier. N'embarque **pas** de `ScrollView` : à placer dans celui de
/// l'appelant (une instance par section, p.ex.).
struct FileTreeView<Leaf, Leading: View, Trailing: View, FolderTrailing: View>: View {
    let items: [FileTreeItem<Leaf>]
    /// Dossiers repliés (par chemin). **Détenu par l'appelant** (`@Binding`) : la source de
    /// vérité vit là où les données vivent → l'arbre se reconstruit de façon fiable quand
    /// `items` change (pas de `@State` interne mal ré-attribué par l'identité structurelle).
    @Binding var collapsed: Set<String>
    var selectedPath: String?
    /// Préfixe d'identité des lignes. **Obligatoire de le rendre distinct** quand plusieurs
    /// `FileTreeView` coexistent (ex. sections indexé/modifié) et peuvent partager des chemins.
    var namespace: String = ""
    let onSelect: (Leaf) -> Void
    @ViewBuilder let leading: (Leaf) -> Leading
    @ViewBuilder let trailing: (Leaf) -> Trailing
    @ViewBuilder let folderTrailing: (String, [Leaf]) -> FolderTrailing

    private var rows: [FileTreeBuilder.Row<Leaf>] {
        FileTreeBuilder.flatten(FileTreeBuilder.build(from: items), collapsed: collapsed, namespace: namespace)
    }

    var body: some View {
        ForEach(rows) { row in
            FileTreeRow(
                row: row,
                isSelected: row.node.value != nil && row.node.id == selectedPath,
                isCollapsed: collapsed.contains(row.id),
                onSelectFile: onSelect,
                onToggleFolder: { toggle(row.id) },
                leading: leading,
                trailing: trailing,
                folderTrailing: folderTrailing
            )
        }
    }

    /// `key` = `Row.id` (déjà préfixé par la section) → pliage indépendant par section.
    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}

/// Une ligne d'arbre (dossier ou fichier). Gère son propre survol pour révéler les actions.
private struct FileTreeRow<Leaf, Leading: View, Trailing: View, FolderTrailing: View>: View {
    let row: FileTreeBuilder.Row<Leaf>
    let isSelected: Bool
    let isCollapsed: Bool
    let onSelectFile: (Leaf) -> Void
    let onToggleFolder: () -> Void
    @ViewBuilder let leading: (Leaf) -> Leading
    @ViewBuilder let trailing: (Leaf) -> Trailing
    @ViewBuilder let folderTrailing: (String, [Leaf]) -> FolderTrailing

    @State private var hovering = false

    /// Largeur d'un cran d'indentation.
    private static var indentStep: CGFloat { 13 }

    var body: some View {
        let node = row.node
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * Self.indentStep, height: 1)
            if node.isDirectory {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 10)
                    .accessibilityHidden(true)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(node.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(node.fileCount)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 6)
                folderTrailing(node.id, node.leafValues)
                    .opacity(hovering ? 1 : 0)
            } else if let value = node.value {
                // Aligne le contenu du fichier sous le nom du dossier parent (chevron + icône).
                Color.clear.frame(width: 10, height: 1)
                leading(value)
                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                trailing(value)
                    .opacity(hovering || isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.06 : 0)))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory { onToggleFolder() }
            else if let value = node.value { onSelectFile(value) }
        }
        .onHover { hovering = $0 }
    }
}
