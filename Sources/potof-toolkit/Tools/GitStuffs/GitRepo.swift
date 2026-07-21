import Foundation

/// Un repo git découvert sur le poste (dossier contenant un `.git`).
struct GitRepo: Identifiable, Hashable {
    let url: URL

    /// Chemin absolu = identité stable (clé de persistance et de sélection).
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    /// Chemin abrégé avec `~` pour l'affichage.
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }

    init(url: URL) {
        self.url = url
    }

    init(path: String) {
        self.url = URL(fileURLWithPath: path)
    }
}
