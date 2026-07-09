import Foundation

/// Un sous-dossier affiché sous forme de carte.
struct FolderItem: Identifiable, Hashable {
    let name: String
    let url: URL

    var id: URL { url }
}
