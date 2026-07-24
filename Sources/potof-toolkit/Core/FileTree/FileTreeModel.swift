import Foundation

/// Modèle **générique** d'arborescence de fichiers, réutilisable par n'importe quel outil
/// (liste des modifications git, fichiers d'un commit, etc.). Ne connaît que des chemins et
/// une valeur opaque `Leaf` : aucune dépendance à git ni à SwiftUI.

/// Une entrée à placer dans l'arbre : un chemin relatif + la valeur portée par la feuille.
struct FileTreeItem<Leaf> {
    let path: String
    let value: Leaf
}

/// Nœud d'arbre : dossier (sans `value`) ou feuille (avec `value`).
struct FileTreeNode<Leaf>: Identifiable {
    /// Chemin complet du nœud = identité stable (clé de repli).
    let id: String
    /// Nom affiché. Pour un dossier à enfant unique compacté : `a/b/c`.
    let name: String
    let isDirectory: Bool
    /// Valeur de la feuille (nil pour un dossier).
    let value: Leaf?
    var children: [FileTreeNode<Leaf>]

    /// Nombre de feuilles sous ce nœud.
    var fileCount: Int {
        isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    /// Toutes les valeurs de feuilles sous ce nœud (pour les actions au niveau dossier).
    var leafValues: [Leaf] {
        if !isDirectory, let value { return [value] }
        return children.flatMap { $0.leafValues }
    }
}

/// Nœud mutable interne au constructeur (ordre d'insertion préservé).
private final class BuildNode<Leaf> {
    let name: String
    let path: String
    var isDirectory: Bool
    var value: Leaf?
    var children: [String: BuildNode<Leaf>] = [:]
    var order: [String] = []
    init(name: String, path: String, isDirectory: Bool) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
    }
}

enum FileTreeBuilder {

    /// Construit l'arbre depuis une liste d'entrées. Dossiers d'abord puis fichiers (alpha).
    /// Les chaînes de dossiers à enfant unique sont **compactées** (`a/b/c` → un seul nœud).
    static func build<Leaf>(from items: [FileTreeItem<Leaf>]) -> [FileTreeNode<Leaf>] {
        let root = BuildNode<Leaf>(name: "", path: "", isDirectory: true)
        for item in items {
            let comps = item.path.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }
            var cur = root
            var acc = ""
            for (i, comp) in comps.enumerated() {
                acc = acc.isEmpty ? comp : acc + "/" + comp
                let isLast = (i == comps.count - 1)
                if let existing = cur.children[comp] {
                    cur = existing
                } else {
                    let node = BuildNode<Leaf>(name: comp, path: acc, isDirectory: !isLast)
                    cur.children[comp] = node
                    cur.order.append(comp)
                    cur = node
                }
                if isLast { cur.value = item.value; cur.isDirectory = false }
            }
        }
        return convert(root)
    }

    private static func convert<Leaf>(_ node: BuildNode<Leaf>) -> [FileTreeNode<Leaf>] {
        let childNodes = node.order.compactMap { node.children[$0] }
        let sorted = childNodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }   // dossiers en premier
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return sorted.map { child in
            guard child.isDirectory else {
                return FileTreeNode(id: child.path, name: child.name,
                                    isDirectory: false, value: child.value, children: [])
            }
            var built = convert(child)
            var name = child.name
            var path = child.path
            // Compaction : tant que le dossier n'a qu'un seul enfant dossier, on fusionne.
            while built.count == 1, built[0].isDirectory {
                name += "/" + built[0].name
                path = built[0].id
                built = built[0].children
            }
            return FileTreeNode(id: path, name: name, isDirectory: true, value: nil, children: built)
        }
    }

    /// Une ligne à afficher : un nœud + sa profondeur (indentation).
    struct Row<Leaf>: Identifiable {
        let id: String
        let node: FileTreeNode<Leaf>
        let depth: Int
    }

    /// Aplati l'arbre en lignes visibles, en masquant les enfants des dossiers repliés.
    ///
    /// `namespace` **préfixe l'`id` de chaque ligne** (pas le chemin du nœud) : indispensable
    /// quand plusieurs `FileTreeView` du même type coexistent (sections indexé/modifié), car
    /// un fichier **partiellement stagé** apparaît dans deux sections avec le même chemin →
    /// sans préfixe, SwiftUI confond les lignes et réutilise la vue de la mauvaise section.
    static func flatten<Leaf>(_ nodes: [FileTreeNode<Leaf>], collapsed: Set<String>,
                              namespace: String = "", depth: Int = 0) -> [Row<Leaf>] {
        var rows: [Row<Leaf>] = []
        for node in nodes {
            // La clé (= `Row.id`) est **préfixée par la section** : le pliage d'un dossier
            // est donc indépendant d'une section à l'autre (un même chemin présent dans
            // « indexé » et « non indexé » ne se déplie plus des deux côtés).
            let key = namespace + "\u{1f}" + node.id
            rows.append(Row(id: key, node: node, depth: depth))
            if node.isDirectory, !collapsed.contains(key) {
                rows.append(contentsOf: flatten(node.children, collapsed: collapsed,
                                                namespace: namespace, depth: depth + 1))
            }
        }
        return rows
    }
}
