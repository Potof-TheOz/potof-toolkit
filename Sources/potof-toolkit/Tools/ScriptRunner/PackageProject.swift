import Foundation

/// Un dossier contenant un `package.json` découvert sur le poste.
/// Identité = chemin absolu du dossier (clé de persistance et de sélection),
/// même convention que `GitRepo`.
struct ScriptPackage: Identifiable, Hashable {
    let dir: URL

    var id: String { dir.path }
    var name: String { dir.lastPathComponent }
    var path: String { dir.path }
    /// Chemin abrégé avec `~` pour l'affichage.
    var displayPath: String { (dir.path as NSString).abbreviatingWithTildeInPath }

    init(dir: URL) {
        self.dir = dir
    }

    init(path: String) {
        self.dir = URL(fileURLWithPath: path)
    }
}

/// Un projet JS/TS : le package **racine** (aucun ancêtre avec `package.json`)
/// et ses packages imbriqués (workspaces d'un monorepo), triés par nom.
struct PackageProject: Identifiable, Hashable {
    let root: ScriptPackage
    let subpackages: [ScriptPackage]

    var id: String { root.id }
    var name: String { root.name }
}
