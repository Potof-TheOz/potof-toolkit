import Foundation

/// Résolution « projet ↔ worktrees » via `git` (shell-out). Couche **fine** au-dessus de
/// `Git.run` ; toute la logique de parsing vit dans `GitProjectParser` (pur). Bloquant :
/// à appeler hors thread principal (comme `RepoDetail`/`WorkingCopyStore`).
enum GitProjectService {

    // MARK: - Identité de projet

    /// `git rev-parse --git-common-dir` **absolu + normalisé** (liens symboliques résolus →
    /// `/private/var` vs `/var`), pour que la clé d'identité soit **stable** entre worktrees
    /// d'un même projet. `nil` si `url` n'est pas dans un repo git.
    static func commonDir(at url: URL) -> String? {
        // `--path-format=absolute` (git ≥ 2.31) garantit un chemin absolu.
        var result = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: url)
        if !result.ok {
            // Fallback vieux git : chemin possiblement relatif → résolu contre `url`.
            result = Git.run(["rev-parse", "--git-common-dir"], in: url)
            guard result.ok else { return nil }
            let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let resolved = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : url.appendingPathComponent(raw)
            return resolved.resolvingSymlinksInPath().path
        }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    // MARK: - Nature d'un `.git`

    /// Classe l'entrée `.git` d'un dossier (pour le scan) : dossier = working tree principal,
    /// fichier = worktree lié ou sous-module (discriminés par le pointeur `gitdir:`).
    static func gitDirKind(at dir: URL) -> GitDirKind {
        let dotGit = dir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else {
            return .other
        }
        if isDir.boolValue { return .mainDir }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return .other }
        return GitProjectParser.classifyGitPointer(contents)
    }

    // MARK: - Énumération des worktrees

    /// `git worktree list --porcelain` depuis n'importe quel dossier du projet (worktree ou
    /// bare), parsé, puis **filtré par existence disque** (écarte les entrées `prunable` :
    /// worktree supprimé mais pas encore `git worktree prune`). Cas limites #2/#4 actés.
    static func worktrees(anyDirOf url: URL) -> [Worktree] {
        let result = Git.run(["worktree", "list", "--porcelain"], in: url)
        guard result.ok else { return [] }
        let fm = FileManager.default
        return GitProjectParser.parseWorktreeList(result.stdout).filter { wt in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: wt.url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: - Résolution complète

    /// Construit le `GitProject` complet à partir de n'importe quel chemin lui appartenant
    /// (worktree, principal ou bare). `nil` si `url` n'est pas un repo git.
    /// Utilisé par « Ajouter un repo… » et par le mapping du scan.
    static func resolveProject(at url: URL) -> GitProject? {
        guard let common = commonDir(at: url) else { return nil }
        let worktrees = worktrees(anyDirOf: url)
        let main = worktrees.first(where: { $0.isMain })
        let name = GitProjectParser.projectName(commonDir: common, mainWorktree: main)
        return GitProject(id: common, name: name, worktrees: worktrees)
    }
}
