import Foundation

/// État d'un fichier dans le working tree, tel que rapporté par `git status`.
///
/// Porcelain sépare deux états : **X = index** (staged) et **Y = copie de travail**
/// (unstaged). Un même fichier peut être **partiellement stagé** (apparaît alors à la
/// fois dans STAGED et dans MODIFIÉ). On conserve donc les deux codes séparément plutôt
/// que la vue fusionnée de `Git.describeStatus`.
struct FileStatus: Identifiable, Hashable {
    /// Chemin relatif à la racine du repo. Pour un renommage : le **nouveau** chemin.
    let path: String
    /// Ancien chemin pour un renommage/copie (côté index), sinon `nil`.
    let originalPath: String?
    /// Code index (X) : ` ` `M` `A` `D` `R` `C` `U` `?` `!`.
    let indexStatus: Character
    /// Code copie de travail (Y).
    let worktreeStatus: Character

    var id: String { path }

    /// Fichier non suivi (`??`).
    var isUntracked: Bool { indexStatus == "?" }
    /// Fichier ignoré (`!!`) — on ne l'affiche pas.
    var isIgnored: Bool { indexStatus == "!" }
    /// Conflit non fusionné (`U` d'un côté, ou `AA` / `DD`).
    var isConflicted: Bool {
        indexStatus == "U" || worktreeStatus == "U"
            || (indexStatus == "A" && worktreeStatus == "A")
            || (indexStatus == "D" && worktreeStatus == "D")
    }
    /// A des changements **indexés** (→ section STAGED).
    /// Porcelain **v2** code « non modifié » = `.` (pas un espace) → on écarte les deux.
    var isStaged: Bool {
        guard !isUntracked, !isIgnored, !isConflicted else { return false }
        return Self.isModified(indexStatus)
    }
    /// A des changements **non indexés** (→ section MODIFIÉ), hors non suivi / conflit.
    var hasUnstagedChanges: Bool {
        guard !isUntracked, !isIgnored, !isConflicted else { return false }
        return Self.isModified(worktreeStatus)
    }

    /// Libellé d'affichage : chemin, ou « ancien → nouveau » pour un renommage.
    var display: String {
        if let originalPath { return "\(originalPath) → \(path)" }
        return path
    }

    /// Lettre de statut à afficher dans une pastille (priorité au plus parlant).
    var badge: Character {
        if isConflicted { return "U" }
        if isUntracked { return "?" }
        if Self.isModified(indexStatus) { return indexStatus }
        return worktreeStatus
    }

    /// Un code d'état porcelain marque-t-il une modification ? (`.` v2 et ` ` v1 = néant.)
    private static func isModified(_ code: Character) -> Bool {
        code != " " && code != "."
    }
}

/// État de synchronisation de la branche courante vis-à-vis de son amont, recalculé
/// après un `git fetch`.
struct RepoSyncState: Equatable {
    /// Nom de l'amont (ex. `origin/main`), ou `nil` si aucun n'est configuré.
    var upstream: String?
    /// Commits **en avance** (locaux non poussés).
    var ahead: Int
    /// Commits **en retard** (distants non récupérés localement) → ⚠️ si > 0.
    var behind: Int
    /// Le dernier fetch a-t-il échoué (auth / réseau) ? `GIT_TERMINAL_PROMPT=0` fait
    /// échouer sans bloquer : on le signale calmement, sans confondre avec « à jour ».
    var fetchFailed: Bool
    /// Date du dernier fetch réussi (`nil` si jamais lancé).
    var lastFetch: Date?

    static let unknown = RepoSyncState(
        upstream: nil, ahead: 0, behind: 0, fetchFailed: false, lastFetch: nil
    )

    var hasUpstream: Bool { upstream != nil }
    var isBehind: Bool { behind > 0 }
    var isAhead: Bool { ahead > 0 }
}

/// Résultat d'une action git d'écriture, remonté à l'UI.
struct GitActionResult {
    let ok: Bool
    /// Message à afficher (erreur si échec, éventuellement info si succès).
    let message: String

    static let success = GitActionResult(ok: true, message: "")
}

/// Contrat des actions git de la couche « working copy ».
///
/// Toutes les méthodes sont **bloquantes** (shell-out synchrone vers `git`) et doivent
/// être appelées **hors du thread principal**. `WorkingCopyStore` s'en charge et republie
/// l'état sur le thread principal. Ce protocole découple la vague UI (store + liste) de la
/// vague d'implémentation (`GitWorkingActions`) : fichiers disjoints.
protocol WorkingCopyServicing {
    /// Stage le fichier entier (`git add -A`, couvre modif/ajout/suppression).
    func stage(path: String, in repo: URL) -> GitActionResult
    /// Déstage le fichier entier (`git restore --staged`).
    func unstage(path: String, in repo: URL) -> GitActionResult
    /// Jette les modifications d'un fichier (non suivi → suppression). **Destructif.**
    func discard(file: FileStatus, in repo: URL) -> GitActionResult
    /// Stage tout (`git add -A`).
    func stageAll(in repo: URL) -> GitActionResult
    /// Déstage tout (`git reset -q HEAD`).
    func unstageAll(in repo: URL) -> GitActionResult
    /// Commit des changements indexés. `body` vide → un seul `-m`.
    func commit(subject: String, body: String, in repo: URL) -> GitActionResult
    /// Push vers l'amont ; `setUpstreamBranch` non `nil` → `push -u origin <branche>`.
    func push(in repo: URL, setUpstreamBranch: String?) -> GitActionResult
    /// `git pull --rebase` (un conflit laisse un rebase en pause → résolution dédiée).
    func pullRebase(in repo: URL) -> GitActionResult
    /// `git fetch` (récupération sans merge, pour l'indicateur ahead/behind).
    func fetch(in repo: URL) -> GitActionResult
    /// Applique un patch (staging par hunk/ligne). `cached` → index ; `reverse` → annule.
    /// - stage hunk : `cached: true,  reverse: false`
    /// - unstage hunk : `cached: true,  reverse: true`
    /// - discard hunk : `cached: false, reverse: true` (**destructif**)
    func applyPatch(_ patch: String, in repo: URL, cached: Bool, reverse: Bool) -> GitActionResult
}
