import Foundation

/// Modèle « projet git » de Git Stuffs, **worktree-aware**.
///
/// L'unité de la feature favoris n'est plus un dossier de repo, mais un **projet** identifié
/// par `git rev-parse --git-common-dir` (chemin absolu, partagé par tous les worktrees d'un
/// même projet). Un projet expose ses **worktrees** (main + liés), énumérés via
/// `git worktree list --porcelain`.
///
/// Ce fichier est **pur** (aucun accès disque ni `git`) : uniquement les modèles + les
/// parseurs. Les shell-outs vivent dans `GitProjectService`. Ainsi le point le plus
/// casse-gueule (parsing) reste isolé et raisonnable à relire.

// MARK: - Worktree

/// Un worktree d'un projet : un dossier de travail avec sa branche (ou HEAD détaché / bare).
struct Worktree: Identifiable, Hashable {
    /// Dossier du working tree.
    let url: URL
    /// Nom de branche court (ex. `main`, `feat/x`), ou `nil` si HEAD détaché / bare.
    let branch: String?
    /// SHA du HEAD (peut être vide, ex. worktree bare).
    let head: String
    /// Worktree **bare** (pas de copie de travail) — jamais ouvrable « en tant que tel ».
    let isBare: Bool
    /// Working tree **principal** du projet (le premier listé par `git worktree list`).
    let isMain: Bool

    /// Chemin absolu = identité stable (clé de sélection + persistance du dernier ouvert).
    var id: String { url.path }
    /// Nom du dossier du worktree (désambiguïse deux worktrees homonymes par branche).
    var folderName: String { url.lastPathComponent }
    /// HEAD abrégé (7 car.) pour l'affichage d'un worktree détaché.
    var shortHead: String { String(head.prefix(7)) }
    /// `true` si HEAD détaché (ni branche, ni bare).
    var isDetached: Bool { branch == nil && !isBare }

    /// Étiquette d'affichage d'un worktree dans le sélecteur (cas limite #6 acté) :
    /// branche si présente, sinon « HEAD détaché <hash> », sinon le nom du dossier.
    var displayLabel: String {
        if let branch { return branch }
        if isBare { return "bare" }
        if isDetached { return "HEAD détaché \(shortHead)" }
        return folderName
    }
}

// MARK: - Projet

/// Un projet git = une identité `--git-common-dir` + ses worktrees.
struct GitProject: Identifiable, Hashable {
    /// `--git-common-dir` **absolu, normalisé** = identité du projet ET clé de favori.
    let id: String
    /// Nom d'affichage du projet (dossier du working tree principal, ou dérivé du common-dir).
    let name: String
    /// Tous les worktrees connus (main + liés). Peut être vide (cas limite #4 : favori sans
    /// worktree existant → ligne grisée).
    let worktrees: [Worktree]

    /// Chemin absolu du common-dir (alias sémantique de `id`).
    var commonDir: String { id }
    /// Worktrees réellement ouvrables (exclut le bare).
    var checkouts: [Worktree] { worktrees.filter { !$0.isBare } }
    /// Le projet a-t-il plusieurs copies de travail → ligne dépliable.
    var isMulti: Bool { checkouts.count > 1 }
    /// Worktree à ouvrir par défaut pour ce projet : le principal s'il existe, sinon le
    /// premier checkout (jamais le bare). `nil` si aucun worktree ouvrable.
    var primary: Worktree? {
        checkouts.first(where: { $0.isMain }) ?? checkouts.first
    }
}

// MARK: - Classification d'un `.git`

/// Nature d'une entrée `.git` rencontrée par le scan.
enum GitDirKind: Equatable {
    /// `.git` est un **dossier** → racine d'un working tree principal.
    case mainDir
    /// `.git` est un **fichier** pointant vers `…/worktrees/…` → worktree lié.
    case worktreeFile
    /// `.git` est un **fichier** pointant vers `…/modules/…` → sous-module (à IGNORER).
    case submoduleFile
    /// Ni l'un ni l'autre (pas un repo, ou pointeur non reconnu).
    case other
}

// MARK: - Parseurs (purs)

enum GitProjectParser {

    /// Classe le **contenu** d'un fichier `.git` (`gitdir: <chemin>`).
    ///
    /// - worktree lié : `gitdir: /abs/mon-repo/.git/worktrees/<nom>`
    /// - sous-module  : `gitdir: ../.git/modules/<nom>`
    static func classifyGitPointer(_ contents: String) -> GitDirKind {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return .other }
        let target = String(trimmed.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        if target.contains("/worktrees/") { return .worktreeFile }
        if target.contains("/modules/") { return .submoduleFile }
        return .other
    }

    /// Parse la sortie `git worktree list --porcelain` en `[Worktree]`, **dans l'ordre**
    /// (le premier bloc = worktree principal → `isMain`). Ne filtre PAS l'existence disque
    /// (c'est le rôle du service, qui écarte les entrées `prunable`).
    ///
    /// Format (blocs séparés par une ligne vide) :
    /// ```
    /// worktree /chemin
    /// HEAD <sha>
    /// branch refs/heads/<nom>        (ou `detached`, ou `bare`)
    /// ```
    static func parseWorktreeList(_ porcelain: String) -> [Worktree] {
        var result: [Worktree] = []

        // Accumulateur du bloc courant.
        var path: String?
        var head = ""
        var branch: String?
        var isBare = false

        func flush() {
            guard let path, !path.isEmpty else { resetBlock(); return }
            let wt = Worktree(
                url: URL(fileURLWithPath: path),
                branch: branch,
                head: head,
                isBare: isBare,
                isMain: result.isEmpty && !isBare   // 1er bloc non-bare = principal
            )
            result.append(wt)
            resetBlock()
        }
        func resetBlock() { path = nil; head = ""; branch = nil; isBare = false }

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { flush(); continue }        // ligne vide = fin de bloc

            if line.hasPrefix("worktree ") {
                // Un nouveau `worktree` sans ligne vide préalable clôt le bloc précédent.
                if path != nil { flush() }
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                branch = nil
            } else if line == "bare" {
                isBare = true
            }
            // `locked`, `prunable`, etc. : ignorés ici (existence filtrée par le service).
        }
        flush()  // dernier bloc (pas toujours suivi d'une ligne vide)
        return result
    }

    /// Nom d'affichage d'un projet à partir de son common-dir (et du principal s'il existe).
    /// - avec working tree principal → son dossier (`…/mon-repo` → `mon-repo`) ;
    /// - sinon (bare) → common-dir sans le suffixe `.git` (`…/mon-repo.git` → `mon-repo`,
    ///   `…/mon-repo/.git` → `mon-repo`).
    static func projectName(commonDir: String, mainWorktree: Worktree?) -> String {
        if let main = mainWorktree { return main.folderName }
        let url = URL(fileURLWithPath: commonDir)
        let last = url.lastPathComponent
        if last == ".git" { return url.deletingLastPathComponent().lastPathComponent }
        if last.hasSuffix(".git") { return String(last.dropLast(".git".count)) }
        return last
    }
}
