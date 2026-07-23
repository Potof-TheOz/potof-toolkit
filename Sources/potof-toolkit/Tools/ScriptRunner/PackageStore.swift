import Foundation
import Combine

/// Découverte et persistance des `package.json` du poste (pattern `RepoStore`).
///
/// - **1er lancement** (cache vide) : scan récursif de `$HOME` en tâche de fond.
/// - **Relances** : lecture du cache UserDefaults (chemins plats), **pas** de re-scan.
/// - **Refresh** : relance explicite du scan.
///
/// Divergence clé vs `RepoStore` : le scan **continue de descendre** dans un projet
/// une fois son `package.json` trouvé (workspaces des monorepos), en élaguant
/// `node_modules` & co. Le groupage racine/sous-packages se fait par remontée
/// d'ancêtres (jamais par tri lexicographique). Un `package.json` directement à
/// `$HOME` est ignoré (parasite qui absorberait tous les projets).
final class PackageStore: ObservableObject {
    /// ⭐ Singleton app-level (comme `ScriptRunStore`) : `RootView` détruit la vue
    /// de l'outil (et ses `@StateObject`) au switch d'outil. Sans singleton,
    /// quitter l'outil pendant le (long) 1er scan de `$HOME` abandonnerait la
    /// nouvelle instance devant une liste vide (`didScanOnce` déjà posé → pas de
    /// re-scan), pendant que le scan orphelin publierait dans le vide. Observer
    /// via `@ObservedObject`.
    static let shared = PackageStore()

    /// Projets groupés (racine + workspaces), triés par nom.
    @Published private(set) var projects: [PackageProject] = []
    @Published private(set) var isScanning = false
    /// Nombre de package.json trouvés par le scan en cours (progression).
    @Published private(set) var foundSoFar = 0

    private let key = "scriptRunner.packageDirs"

    /// Dossiers dont on ne descend jamais le contenu (lourds ou hors sujet).
    /// Mêmes noms que `RepoStore` + les sorties de build JS (`out`, `coverage`).
    private static let prunedDirectoryNames: Set<String> = [
        "node_modules", "Library", ".Trash", "Applications",
        "Pods", "vendor", "target", "dist", "build",
        ".build", "DerivedData", ".cache", ".npm", ".gradle",
        "Music", "Movies", "Pictures", "Photos Library.photoslibrary",
        "out", "coverage",
    ]

    private init() {
        loadCache()
    }

    // MARK: - Cache

    private func loadCache() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let fm = FileManager.default
        // On écarte les packages disparus depuis le dernier scan (package.json supprimé).
        let alive = paths.filter { path in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path + "/package.json", isDirectory: &isDir)
                && !isDir.boolValue
        }
        projects = Self.group(paths: alive, home: fm.homeDirectoryForCurrentUser.path)
    }

    private func persist(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: key)
    }

    // MARK: - Scan

    /// (Re)lance un scan de `$HOME` en tâche de fond. Un seul scan à la fois.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        foundSoFar = 0

        let home = FileManager.default.homeDirectoryForCurrentUser
        // `self` est un singleton (jamais désalloué) : capture forte sans risque.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.discoverPackageDirs(under: home) { count in
                // Republie la progression sur le thread principal, sans saturer :
                // les packages sont assez rares pour qu'un push par découverte suffise.
                DispatchQueue.main.async { self.foundSoFar = count }
            }
            let grouped = Self.group(paths: found, home: home.path)
            DispatchQueue.main.async {
                self.projects = grouped
                self.persist(found)
                self.isScanning = false
            }
        }
    }

    /// Parcours récursif (pile explicite) élaguant les dossiers inutiles.
    /// Inverse de `RepoStore` : un `package.json` (fichier) est enregistré **et on
    /// continue de descendre** (les workspaces d'un monorepo vivent sous la racine).
    /// Retourne la liste **plate** des dossiers (chemins absolus), à grouper ensuite.
    private func discoverPackageDirs(under root: URL, onProgress: (Int) -> Void) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        var stack: [URL] = [root]
        let homePath = root.path

        while let dir = stack.popLast() {
            // Un `package.json` (fichier) marque un package. Celui directement à
            // `$HOME` est ignoré : il absorberait tous les projets en sous-entrées.
            var manifestIsDir: ObjCBool = false
            if dir.path != homePath,
               fm.fileExists(atPath: dir.appendingPathComponent("package.json").path,
                             isDirectory: &manifestIsDir),
               !manifestIsDir.boolValue {
                results.append(dir.path)
                onProgress(results.count)
            }

            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                // Cachés et dossiers lourds : élagués.
                if name.hasPrefix(".") { continue }
                if Self.prunedDirectoryNames.contains(name) { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard values?.isDirectory == true else { continue }
                // Ne PAS descendre dans les bundles (.app, .xcarchive,
                // .photoslibrary…) : l'option `.skipsPackageDescendants` est sans
                // effet sur `contentsOfDirectory` (énumération shallow), donc on
                // filtre explicitement via `isPackage` — sinon un `.app` Electron
                // dans ~/Downloads exposerait son package.json interne comme projet.
                if values?.isPackage == true { continue }
                stack.append(entry)
            }
        }
        return results
    }

    // MARK: - Groupage

    /// Groupe la liste plate en projets : pour chaque dossier, on remonte ses
    /// ancêtres (jusqu'à `$HOME` exclu) et l'ancêtre le **plus haut** présent dans
    /// le `Set` des dossiers trouvés est sa racine ; aucun ancêtre → il est
    /// lui-même racine. ⚠️ Pas de « racine courante » sur tri lexicographique :
    /// `/a/b-x` s'intercale entre `/a/b` et `/a/b/c` et casserait le groupage.
    private static func group(paths: [String], home: String) -> [PackageProject] {
        let set = Set(paths)
        var rootPaths: [String] = []
        var subsByRoot: [String: [String]] = [:]

        for path in set {
            var highest: String?
            var cursor = (path as NSString).deletingLastPathComponent
            while cursor != home, cursor.count > 1 {
                if set.contains(cursor) { highest = cursor }
                cursor = (cursor as NSString).deletingLastPathComponent
            }
            if let root = highest {
                subsByRoot[root, default: []].append(path)
            } else {
                rootPaths.append(path)
            }
        }

        return rootPaths
            .map { root in
                let subs = (subsByRoot[root] ?? [])
                    .map { ScriptPackage(path: $0) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return PackageProject(root: ScriptPackage(path: root), subpackages: subs)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
