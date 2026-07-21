import Foundation
import Combine

/// Charge l'état lisible d'un repo sélectionné : branche courante + commits de
/// cette branche. Lecture seule (aucune mutation du repo).
final class RepoDetail: ObservableObject {
    @Published private(set) var branch: String = ""
    /// `true` si HEAD est détaché (pas sur une branche nommée).
    @Published private(set) var isDetached = false
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// Un rebase est-il déjà en cours dans ce repo (laissé par une session passée) ?
    @Published private(set) var rebaseInProgress = false
    /// L'arbre de travail est-il propre ? (garde-fou d'éligibilité au rebase).
    @Published private(set) var treeClean = true
    /// Branche amont configurée (ex. `origin/feat/xxx`), ou `nil` si aucune. Cible
    /// du `push --force-with-lease` proposé après un rebase.
    @Published private(set) var upstream: String?
    /// Hashes des commits **déjà poussés** (atteignables depuis `@{upstream}`). Purement
    /// informatif : on autorise leur réécriture (force-push assumé), mais on l'indique.
    @Published private(set) var pushedHashes: Set<String> = []
    /// Hashes des commits **propres à la branche courante** : postérieurs à son point de
    /// divergence d'avec la branche de base. Rebaser un commit HORS de cet ensemble
    /// (antérieur à la création de la branche, donc partagé avec la base) est **interdit**.
    /// Si la base est indéterminée, ou si on EST sur la branche de base, contient tous les
    /// commits affichés (aucune restriction).
    @Published private(set) var branchOwnHashes: Set<String> = []
    /// Nom court de la branche de base détectée (ex. « main »), pour étiqueter le point de
    /// création dans le graphe. `nil` si indéterminée ou si on est dessus.
    @Published private(set) var baseBranchName: String?

    /// Nombre max de commits chargés pour le graphe (borne la perf sur gros repos).
    static let commitLimit = 200

    private let repoURL: URL
    /// Sépare les champs d'une ligne `git log` (unit separator, absent des messages).
    private static let fieldSeparator = "\u{1f}"

    init(repo: URL) {
        self.repoURL = repo
    }

    /// (Re)charge branche + commits en tâche de fond.
    func load() {
        isLoading = true
        loadError = nil
        let repo = repoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let inProgress = Self.detectRebaseInProgress(repo: repo)

            let branchResult = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            let branchName = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detached = (branchName == "HEAD")

            // Arbre propre ? (garde-fou d'éligibilité, revérifié avant tout rebase).
            let status = Git.run(["status", "--porcelain"], in: repo)
            let clean = status.ok && status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // Branche amont (cible du force-push) et commits déjà poussés (informatif).
            let upstreamResult = Git.run(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repo
            )
            let upstreamRef = upstreamResult.ok
                ? upstreamResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            var pushed: Set<String> = []
            if upstreamRef != nil {
                // Commits atteignables depuis l'amont = déjà poussés.
                let reachable = Git.run(["rev-list", "@{upstream}"], in: repo)
                if reachable.ok {
                    pushed = Set(reachable.stdout.split(separator: "\n").map(String.init))
                }
            }

            let format = ["%H", "%h", "%s", "%an", "%ar", "%P"].joined(separator: Self.fieldSeparator)
            let logResult = Git.run(
                ["log", "-n", "\(Self.commitLimit)", "--pretty=format:\(format)"],
                in: repo
            )

            let parsed: [GitCommit]
            var error: String?
            if branchResult.ok && logResult.ok {
                parsed = Self.parseCommits(logResult.stdout)
            } else {
                parsed = []
                // Un repo tout neuf (aucun commit) n'est pas une erreur : liste vide.
                let msg = logResult.ok ? branchResult.message : logResult.message
                if !msg.localizedCaseInsensitiveContains("does not have any commits") {
                    error = msg.isEmpty ? "Impossible de lire l'historique." : msg
                }
            }

            // Point de divergence : commits propres à la branche (après le fork d'avec la
            // base). Par défaut, tout est « propre à la branche » = aucune restriction.
            var ownHashes = Set(parsed.map(\.hash))
            var baseShort: String?
            if !detached, let base = Self.detectBaseBranch(repo: repo, current: branchName) {
                let fork = Git.run(["merge-base", "HEAD", base.ref], in: repo)
                if fork.ok {
                    let forkHash = fork.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let own = Git.run(["rev-list", "\(forkHash)..HEAD"], in: repo)
                    if own.ok {
                        ownHashes = Set(own.stdout.split(separator: "\n").map(String.init))
                        baseShort = base.short
                    }
                }
            }

            DispatchQueue.main.async {
                self.branch = detached ? "HEAD détaché" : branchName
                self.isDetached = detached
                self.commits = parsed
                self.loadError = error
                self.rebaseInProgress = inProgress
                self.treeClean = clean
                self.upstream = upstreamRef
                self.pushedHashes = pushed
                self.branchOwnHashes = ownHashes
                self.baseBranchName = baseShort
                self.isLoading = false
            }
        }
    }

    private static func parseCommits(_ output: String) -> [GitCommit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.components(separatedBy: fieldSeparator)
            guard fields.count == 6 else { return nil }
            // `%P` = hashes des parents séparés par des espaces → merge si > 1.
            let parents = fields[5].split(separator: " ", omittingEmptySubsequences: true)
            return GitCommit(
                hash: fields[0],
                shortHash: fields[1],
                subject: fields[2],
                author: fields[3],
                relativeDate: fields[4],
                isMerge: parents.count > 1
            )
        }
    }

    /// Détecte la branche de base (celle dont la branche courante a divergé) pour situer
    /// le point de création. Essaie la branche par défaut du remote (`origin/HEAD`) puis
    /// des noms usuels (remote puis local). Écarte la branche courante elle-même.
    /// Renvoie `nil` si rien de pertinent n'existe (→ aucune restriction de rebase).
    private static func detectBaseBranch(repo: URL, current: String) -> (ref: String, short: String)? {
        var candidates: [String] = []
        let originHead = Git.run(["rev-parse", "--abbrev-ref", "origin/HEAD"], in: repo)
        if originHead.ok {
            let ref = originHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty && ref != "origin/HEAD" { candidates.append(ref) }
        }
        candidates += ["origin/main", "origin/master", "origin/develop", "main", "master", "develop"]

        for ref in candidates {
            let short = ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
            if short == current { continue }          // on est sur la base → pas de restriction
            let verify = Git.run(["rev-parse", "--verify", "--quiet", ref], in: repo)
            if verify.ok && !verify.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (ref, short)
            }
        }
        return nil
    }

    /// Un rebase est en cours si git a laissé un dossier `rebase-merge`/`rebase-apply`
    /// dans le répertoire git. Robuste aux worktrees (`--absolute-git-dir`).
    static func detectRebaseInProgress(repo: URL) -> Bool {
        let result = Git.run(["rev-parse", "--absolute-git-dir"], in: repo)
        guard result.ok else { return false }
        let gitDir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDir.isEmpty else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: gitDir + "/rebase-merge")
            || fm.fileExists(atPath: gitDir + "/rebase-apply")
    }
}
