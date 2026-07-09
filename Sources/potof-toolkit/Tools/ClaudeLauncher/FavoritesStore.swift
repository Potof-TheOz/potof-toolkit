import Foundation
import Combine

/// Favoris de Claude Launcher : chemins absolus de dossiers, persistés dans
/// UserDefaults. Indépendants du dossier racine courant.
final class FavoritesStore: ObservableObject {
    @Published private(set) var paths: [String]

    private let key = "claudeLauncher.favorites"

    init() {
        paths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isFavorite(_ path: String) -> Bool {
        paths.contains(path)
    }

    func toggle(_ path: String) {
        if let index = paths.firstIndex(of: path) {
            paths.remove(at: index)
        } else {
            paths.append(path)
        }
        UserDefaults.standard.set(paths, forKey: key)
    }
}
