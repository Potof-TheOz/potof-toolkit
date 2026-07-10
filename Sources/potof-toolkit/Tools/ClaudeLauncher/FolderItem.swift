import Foundation

/// Un sous-dossier affiché sous forme de carte.
struct FolderItem: Identifiable, Hashable {
    let name: String
    let url: URL
    /// Y a-t-il un `CLAUDE.md` à la racine du dossier ? Calculé une fois à la
    /// construction (au scan / au chargement des favoris) pour éviter un accès
    /// disque à chaque rendu de ligne. L'UI affiche alors la marque Claude.
    let hasClaudeMd: Bool

    var id: URL { url }

    init(url: URL) {
        self.name = url.lastPathComponent
        self.url = url
        self.hasClaudeMd = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("CLAUDE.md").path)
    }
}
