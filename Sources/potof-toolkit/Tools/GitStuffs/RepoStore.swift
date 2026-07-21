import Foundation
import Combine

/// Découverte et persistance des repos git du poste.
///
/// - **1er lancement** (cache vide) : scan récursif de `$HOME` en tâche de fond.
/// - **Relances** : lecture du cache UserDefaults, **pas** de re-scan automatique.
/// - **Refresh** : relance explicite du scan.
///
/// Le scan élague les dossiers lourds/inutiles et **ne descend pas** dans un repo
/// une fois son `.git` détecté (cf. cahier des charges) pour rester rapide.
final class RepoStore: ObservableObject {
    @Published private(set) var repos: [GitRepo] = []
    @Published private(set) var isScanning = false
    /// Nombre de repos trouvés par le scan en cours (indicateur de progression).
    @Published private(set) var foundSoFar = 0

    private let key = "gitStuffs.repos"

    /// Dossiers dont on ne descend jamais le contenu (lourds ou hors sujet).
    private static let prunedDirectoryNames: Set<String> = [
        "node_modules", "Library", ".Trash", "Applications",
        "Pods", "vendor", "target", "dist", "build",
        ".build", "DerivedData", ".cache", ".npm", ".gradle",
        "Music", "Movies", "Pictures", "Photos Library.photoslibrary",
    ]

    init() {
        loadCache()
    }

    // MARK: - Cache

    private func loadCache() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let fm = FileManager.default
        // On écarte les repos disparus depuis le dernier scan (dossier supprimé).
        repos = paths
            .filter { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path + "/.git", isDirectory: &isDir)
            }
            .map { GitRepo(path: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func persist(_ repos: [GitRepo]) {
        UserDefaults.standard.set(repos.map(\.path), forKey: key)
    }

    // MARK: - Scan

    /// (Re)lance un scan de `$HOME` en tâche de fond. Un seul scan à la fois.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        foundSoFar = 0

        let home = FileManager.default.homeDirectoryForCurrentUser
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let found = self.discoverRepos(under: home) { count in
                // Republie la progression sur le thread principal, sans saturer :
                // les repos sont assez rares pour qu'un push par découverte suffise.
                DispatchQueue.main.async { self.foundSoFar = count }
            }
            let sorted = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.repos = sorted
                self.persist(sorted)
                self.isScanning = false
            }
        }
    }

    /// Parcours récursif (pile explicite) élaguant les dossiers inutiles et
    /// s'arrêtant à la racine d'un repo. **Statique dans l'esprit** : n'accède à
    /// aucun état publié (le callback de progression fait le pont vers l'UI).
    private func discoverRepos(under root: URL, onProgress: (Int) -> Void) -> [GitRepo] {
        let fm = FileManager.default
        var results: [GitRepo] = []
        var stack: [URL] = [root]

        while let dir = stack.popLast() {
            // Un `.git` (dossier) marque la racine d'un repo : on l'enregistre et on
            // ne descend PAS dedans (ni dans ses sous-dossiers).
            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &gitIsDir),
               gitIsDir.boolValue {
                results.append(GitRepo(url: dir))
                onProgress(results.count)
                continue
            }

            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                // Cachés (dont `.git` déjà traité) et dossiers lourds : élagués.
                if name.hasPrefix(".") { continue }
                if Self.prunedDirectoryNames.contains(name) { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    stack.append(entry)
                }
            }
        }
        return results
    }
}
