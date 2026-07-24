import Foundation
import Combine

/// Source de vérité du sélecteur de Git Stuffs, **worktree-aware** et **centrée favoris**.
///
/// Remplace `RepoStore` : l'unité n'est plus un dossier de repo mais un **projet**
/// (`--git-common-dir`), dont les **worktrees** sont énumérés à la demande.
///
/// Stratégie de coût (cf. plan §7) :
/// - **Identité** (regrouper les dossiers scannés en projets) : un `--git-common-dir` par
///   dossier, mais **mis en cache** (`pathMapKey`) → démarrage sans git après le 1er scan.
/// - **Worktrees** (enfants + branches) : `git worktree list` lancé **paresseusement**, quand
///   une ligne apparaît (`ensureLoaded`, appelé en `.onAppear`), pour les favoris et les
///   projets visibles — **jamais** pour tous les projets d'un coup.
///
/// `ProjectStore` n'est **pas** process-backed → `@StateObject` dans `GitStuffsView` est
/// correct (comme l'ancien `RepoStore`). Toutes les mutations sont publiées sur le thread
/// principal ; git tourne en tâche de fond.
final class ProjectStore: ObservableObject {

    // MARK: - État publié

    /// Tous les projets connus (dédupliqués par common-dir, triés alpha). Leurs worktrees ne
    /// sont PAS remplis ici : voir `worktrees(for:)` / `loadedWorktrees`.
    @Published private(set) var allProjects: [GitProject] = []
    /// Common-dirs favoris (clé d'identité de projet).
    @Published private(set) var favorites: Set<String> = []
    /// Worktrees chargés (authoritative) par projet. `nil` = pas encore chargé.
    @Published private(set) var loadedWorktrees: [String: [Worktree]] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var foundSoFar = 0
    /// Message transitoire (ex. worktree disparu) affiché puis effacé par la vue.
    @Published var transientMessage: String?

    // MARK: - Dérivés

    /// Projets favoris (présents dans le scan **ou** synthétiques si dangling → cas limite #4 :
    /// un favori dont le projet n'est plus scanné reste visible, grisé « aucun worktree »).
    var favoriteProjects: [GitProject] {
        let present = allProjects.filter { favorites.contains($0.id) }
        let presentIDs = Set(present.map(\.id))
        let dangling = favorites.subtracting(presentIDs).map { common in
            GitProject(id: common,
                       name: GitProjectParser.projectName(commonDir: common, mainWorktree: nil),
                       worktrees: [])
        }
        return (present + dangling)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func worktrees(for project: GitProject) -> [Worktree] { loadedWorktrees[project.id] ?? [] }
    func isLoaded(_ project: GitProject) -> Bool { loadedWorktrees[project.id] != nil }
    func isFavorite(_ project: GitProject) -> Bool { favorites.contains(project.id) }

    /// Projet propriétaire d'un worktree (via les worktrees déjà chargés — le worktree courant
    /// l'est toujours, sa sélection ayant mis en cache les worktrees de son projet). Sert au
    /// sélecteur de worktree de la barre du haut.
    func project(containing worktree: Worktree) -> GitProject? {
        for (common, wts) in loadedWorktrees where wts.contains(where: { $0.id == worktree.id }) {
            if let known = (allProjects + favoriteProjects).first(where: { $0.id == common }) { return known }
            let main = wts.first(where: { $0.isMain })
            return GitProject(id: common,
                              name: GitProjectParser.projectName(commonDir: common, mainWorktree: main),
                              worktrees: [])
        }
        return nil
    }

    /// Worktree à ouvrir par défaut pour un projet chargé (principal, sinon 1er checkout).
    func primaryWorktree(for project: GitProject) -> Worktree? {
        let wts = worktrees(for: project)
        return wts.first(where: { $0.isMain && !$0.isBare }) ?? wts.first(where: { !$0.isBare })
    }

    // MARK: - Privé (état non publié)

    /// `chemin de working tree → common-dir` (cache d'identité persistant).
    private var pathToCommon: [String: String] = [:]
    /// `common-dir → chemins de working trees connus` (pour ancrer `git worktree list`).
    private var projectPaths: [String: [String]] = [:]
    /// Projets dont le chargement des worktrees est en vol (anti-doublon).
    private var loading: Set<String> = []

    private let reposKey = "gitStuffs.repos"            // réutilise le cache de scan existant
    private let pathMapKey = "gitStuffs.projectMap"
    private let favoritesKey = "gitStuffs.favorites"
    private let lastSelectedKey = "gitStuffs.lastSelected"

    /// Dossiers dont on ne descend jamais le contenu (repris de `RepoStore`).
    private static let prunedDirectoryNames: Set<String> = [
        "node_modules", "Library", ".Trash", "Applications",
        "Pods", "vendor", "target", "dist", "build",
        ".build", "DerivedData", ".cache", ".npm", ".gradle",
        "Music", "Movies", "Pictures", "Photos Library.photoslibrary",
    ]

    // MARK: - Init / cache

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        loadFromCache()
    }

    /// Reconstruit les projets depuis le cache disque, **sans git** pour les chemins déjà
    /// mappés (démarrage instantané) ; résout en fond les rares chemins non mappés.
    private func loadFromCache() {
        let paths = (UserDefaults.standard.stringArray(forKey: reposKey) ?? [])
            .filter { Self.isGitWorkingTree($0) }
        var map = UserDefaults.standard.dictionary(forKey: pathMapKey) as? [String: String] ?? [:]

        let mapped = paths.filter { map[$0] != nil }
        let (projects, byProject) = Self.buildProjects(paths: mapped, map: map)
        self.pathToCommon = map
        self.projectPaths = byProject
        self.allProjects = projects

        let unmapped = paths.filter { map[$0] == nil }
        guard !unmapped.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for p in unmapped {
                if let c = GitProjectService.commonDir(at: URL(fileURLWithPath: p)) { map[p] = c }
            }
            let (proj, byProj) = Self.buildProjects(paths: paths.filter { map[$0] != nil }, map: map)
            DispatchQueue.main.async {
                self.pathToCommon = map
                self.projectPaths = byProj
                self.allProjects = proj
                UserDefaults.standard.set(map, forKey: self.pathMapKey)
            }
        }
    }

    /// Regroupe des chemins de working trees en projets (par common-dir), triés alpha.
    private static func buildProjects(paths: [String], map: [String: String])
        -> (projects: [GitProject], byProject: [String: [String]]) {
        var byProject: [String: [String]] = [:]
        for p in paths {
            guard let common = map[p] else { continue }
            byProject[common, default: []].append(p)
        }
        let projects = byProject.keys.map { common in
            GitProject(id: common,
                       name: GitProjectParser.projectName(commonDir: common, mainWorktree: nil),
                       worktrees: [])
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (projects, byProject)
    }

    private static func isGitWorkingTree(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }

    // MARK: - Chargement paresseux des worktrees

    /// Charge les worktrees d'un projet s'ils ne le sont pas déjà (appelé en `.onAppear` des
    /// lignes visibles + à la mise en favori).
    func ensureLoaded(_ project: GitProject) {
        guard loadedWorktrees[project.id] == nil, !loading.contains(project.id) else { return }
        load(project, force: false)
    }

    /// Force un rechargement (retour au premier plan, après une opération).
    func refreshWorktrees(for project: GitProject) { load(project, force: true) }

    private func load(_ project: GitProject, force: Bool) {
        if !force && loading.contains(project.id) { return }
        let candidates = (projectPaths[project.id] ?? []).filter { Self.isGitWorkingTree($0) }
        guard let anchor = candidates.first else {
            loadedWorktrees[project.id] = []          // dangling → grisé « aucun worktree »
            return
        }
        loading.insert(project.id)
        let url = URL(fileURLWithPath: anchor)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wts = GitProjectService.worktrees(anyDirOf: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(project.id)
                self.loadedWorktrees[project.id] = wts
            }
        }
    }

    // MARK: - Favoris

    func toggleFavorite(_ project: GitProject) {
        if favorites.contains(project.id) {
            favorites.remove(project.id)
        } else {
            favorites.insert(project.id)
            ensureLoaded(project)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    // MARK: - Scan

    /// (Re)lance un scan de `$HOME` : découvre les working trees (dossiers `.git` **et**
    /// fichiers `.git` de worktree ; **saute** les sous-modules), résout leur common-dir,
    /// regroupe en projets. Un seul scan à la fois.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        foundSoFar = 0
        let home = FileManager.default.homeDirectoryForCurrentUser
        var map = self.pathToCommon
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let paths = self.discoverWorkingTrees(under: home) { count in
                DispatchQueue.main.async { self.foundSoFar = count }
            }
            for p in paths where map[p] == nil {
                if let c = GitProjectService.commonDir(at: URL(fileURLWithPath: p)) { map[p] = c }
            }
            // On ne jette que les chemins RÉELLEMENT disparus du disque : les repos connus
            // toujours présents mais non redécouverts par le scan de `$HOME` (ex. ajoutés à la
            // main hors `$HOME`) sont **préservés**. Évite qu'un favori hors `$HOME` devienne
            // dangling après un simple re-scan.
            map = map.filter { Self.isGitWorkingTree($0.key) }
            let knownPaths = Array(map.keys)
            let (projects, byProject) = Self.buildProjects(paths: knownPaths, map: map)
            DispatchQueue.main.async {
                self.pathToCommon = map
                self.projectPaths = byProject
                self.allProjects = projects
                UserDefaults.standard.set(knownPaths, forKey: self.reposKey)
                UserDefaults.standard.set(map, forKey: self.pathMapKey)
                self.isScanning = false
            }
        }
    }

    /// Parcours récursif (pile explicite) élaguant les dossiers lourds et s'arrêtant à la
    /// racine d'un working tree (dossier `.git` = principal, fichier `.git` = worktree lié ;
    /// un sous-module — pointeur `modules/` — est **ignoré et non descendu**).
    private func discoverWorkingTrees(under root: URL, onProgress: (Int) -> Void) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        var stack: [URL] = [root]

        while let dir = stack.popLast() {
            switch GitProjectService.gitDirKind(at: dir) {
            case .mainDir, .worktreeFile:
                results.append(dir.path)
                onProgress(results.count)
                continue                       // ne descend pas dans un repo/worktree
            case .submoduleFile:
                continue                       // sous-module : ignoré, non descendu
            case .other:
                break                          // pas un repo : on descend
            }

            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") { continue }
                if Self.prunedDirectoryNames.contains(name) { continue }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true { stack.append(entry) }
            }
        }
        return results
    }

    // MARK: - Ajouter un repo (NSOpenPanel)

    enum AddError: Error {
        case notGit, submodule
        var message: String {
            switch self {
            case .notGit: return "Ce dossier n'est pas un repo git."
            case .submodule: return "Ce dossier est un sous-module git (non géré)."
            }
        }
    }

    /// Résout le projet d'un dossier choisi, le **favorise d'office**, l'enregistre, et renvoie
    /// le worktree à sélectionner (le principal, sinon le 1er checkout).
    func addProject(at url: URL, completion: @escaping (Result<Worktree, AddError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func finish(_ r: Result<Worktree, AddError>) { DispatchQueue.main.async { completion(r) } }
            if GitProjectService.gitDirKind(at: url) == .submoduleFile { return finish(.failure(.submodule)) }
            guard let project = GitProjectService.resolveProject(at: url) else { return finish(.failure(.notGit)) }
            if project.id.contains("/.git/modules/") { return finish(.failure(.submodule)) }
            guard let primary = project.primary else { return finish(.failure(.notGit)) }

            DispatchQueue.main.async {
                guard let self else { return }
                self.register(project)
                self.favorites.insert(project.id)
                UserDefaults.standard.set(Array(self.favorites), forKey: self.favoritesKey)
                completion(.success(primary))
            }
        }
    }

    /// Intègre un projet résolu au cache en mémoire + persistance (idempotent).
    private func register(_ project: GitProject) {
        loadedWorktrees[project.id] = project.worktrees
        var paths = projectPaths[project.id] ?? []
        for w in project.worktrees where !paths.contains(w.url.path) { paths.append(w.url.path) }
        projectPaths[project.id] = paths
        for w in project.worktrees { pathToCommon[w.url.path] = project.id }
        if !allProjects.contains(where: { $0.id == project.id }) {
            allProjects = (allProjects + [GitProject(id: project.id, name: project.name, worktrees: [])])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // Persiste l'union des chemins connus + la map (pour un rebuild propre au prochain lancement).
        let allPaths = Array(pathToCommon.keys)
        UserDefaults.standard.set(allPaths, forKey: reposKey)
        UserDefaults.standard.set(pathToCommon, forKey: pathMapKey)
    }

    // MARK: - Sélection : dernier ouvert + repli

    func rememberSelection(_ worktree: Worktree) {
        UserDefaults.standard.set(worktree.url.path, forKey: lastSelectedKey)
    }

    /// Résout le worktree à ouvrir au lancement (chaîne de repli §1). Asynchrone : git en fond.
    func resolveInitialSelection(_ completion: @escaping (Worktree?) -> Void) {
        let last = UserDefaults.standard.string(forKey: lastSelectedKey)
        resolveSelection(preferredPath: last, completion: completion)
    }

    /// Rafraîchit favoris + projet courant au premier plan ; si le worktree courant a disparu,
    /// renvoie un worktree de repli (sinon `nil` = pas de changement).
    func refreshOnForeground(current: Worktree?, _ completion: @escaping (Worktree?) -> Void) {
        for p in favoriteProjects { refreshWorktrees(for: p) }
        if let current, let common = pathToCommon[current.url.path],
           let proj = (allProjects + favoriteProjects).first(where: { $0.id == common }) {
            refreshWorktrees(for: proj)
        }
        guard let current, !Self.isGitWorkingTree(current.url.path) else {
            transientMessage = nil          // rien n'a disparu → nettoie un message résiduel
            return completion(nil)
        }
        transientMessage = "Le worktree « \(current.folderName) » a disparu — retour sur le projet."
        resolveSelection(preferredPath: current.url.path, completion: completion)
    }

    /// Cœur de la résolution (fond) : dernier worktree → principal du projet → 1er checkout →
    /// projet favori suivant → nil. Met en cache les worktrees du projet retenu.
    private func resolveSelection(preferredPath: String?, completion: @escaping (Worktree?) -> Void) {
        let favIDs = favoriteProjects.map(\.id)
        let byProject = projectPaths
        let map = pathToCommon
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = Self.resolve(preferredPath: preferredPath,
                                        favoriteProjectIDs: favIDs,
                                        projectPaths: byProject,
                                        pathToCommon: map)
            DispatchQueue.main.async {
                guard let self else { return completion(nil) }
                if let resolved { self.loadedWorktrees[resolved.project.id] = resolved.project.worktrees }
                completion(resolved?.worktree)
            }
        }
    }

    private static func resolve(preferredPath: String?, favoriteProjectIDs: [String],
                                projectPaths: [String: [String]], pathToCommon: [String: String])
        -> (worktree: Worktree, project: GitProject)? {

        func firstExisting(_ id: String) -> String? {
            (projectPaths[id] ?? []).first { isGitWorkingTree($0) }
        }
        func build(anchor: String, prefer: String?) -> (Worktree, GitProject)? {
            guard let project = GitProjectService.resolveProject(at: URL(fileURLWithPath: anchor)) else { return nil }
            let wt = prefer.flatMap { p in project.worktrees.first { $0.url.path == p } } ?? project.primary
            guard let wt else { return nil }
            return (wt, project)
        }

        // 1. dernier worktree ouvert, s'il existe encore.
        if let last = preferredPath, isGitWorkingTree(last), let r = build(anchor: last, prefer: last) {
            return r
        }
        // 2. même projet : principal (branche courante) → 1er checkout existant.
        if let last = preferredPath, let common = pathToCommon[last], let anchor = firstExisting(common),
           let r = build(anchor: anchor, prefer: nil) {
            return r
        }
        // 3. projet favori suivant (ordre alpha).
        for id in favoriteProjectIDs {
            if let anchor = firstExisting(id), let r = build(anchor: anchor, prefer: nil) { return r }
        }
        return nil
    }
}
