import Foundation
import Combine

/// Action appliquée à un commit dans un rebase interactif (mots-clés git).
enum RebaseAction: String, CaseIterable, Identifiable {
    case pick, reword, edit, squash, fixup, drop

    var id: String { rawValue }

    /// Libellé du picker : mot-clé git + intention en français.
    var label: String {
        switch self {
        case .pick:   return "pick — garder"
        case .reword: return "reword — renommer"
        case .edit:   return "edit — mettre en pause"
        case .squash: return "squash — fusionner (avec message)"
        case .fixup:  return "fixup — fusionner (sans message)"
        case .drop:   return "drop — supprimer"
        }
    }

    /// Les actions de fusion se rattachent au commit précédent : illégales en tête.
    var isMeld: Bool { self == .squash || self == .fixup }
}

/// Une ligne du plan de rebase : un commit + l'action choisie. Réordonnable.
struct RebaseStep: Identifiable, Hashable {
    let id: String            // hash complet du commit (identité stable)
    let shortHash: String
    let originalSubject: String
    /// Commit de fusion : bloque le rebase (le mode interactif aplatirait le merge).
    let isMerge: Bool
    var action: RebaseAction = .pick
    /// Nouveau message pour `reword` (pré-rempli avec le sujet courant).
    var newMessage: String

    init(commit: GitCommit) {
        self.id = commit.hash
        self.shortHash = commit.shortHash
        self.originalSubject = commit.subject
        self.isMerge = commit.isMerge
        self.newMessage = commit.subject
    }
}

/// Pilote un rebase interactif **réel** sur un repo, en shell-out vers `git`.
///
/// Mécanique (sans lib git, cf. CLAUDE.md) :
/// - `GIT_SEQUENCE_EDITOR` pointe vers un petit script temp qui **écrase** le fichier
///   todo de git (chemin passé en `$1`) par le todo généré depuis l'UI.
/// - `reword` est réalisé non-interactivement par `pick` + `exec git commit --amend -m …`
///   (pas de dépendance à un éditeur de message par commit).
/// - `GIT_EDITOR=true` : pour un `squash`, le message combiné par défaut est accepté
///   sans éditeur bloquant.
/// - `edit` / conflit : git **s'arrête** et rend la main ; on détecte le rebase en cours
///   et on propose `--continue` / `--abort` (repo toujours récupérable).
///
/// Garde-fous : refus si l'arbre de travail n'est pas propre ; confirmation explicite
/// côté UI ; jamais de `push`, de `--force`, ni d'écriture hors du repo ciblé.
final class RebaseController: ObservableObject, Identifiable {
    /// Identité stable : permet de présenter le panneau via `.sheet(item:)` (le
    /// contrôleur n'est jamais nil au moment du rendu → plus de feuille vide).
    let id = UUID()

    enum Phase: Equatable {
        case editing     // construction du plan
        case running     // git travaille
        case paused      // rebase arrêté (edit ou conflit) → continue / abort
        case finished    // terminé (succès ou abandon) → l'historique a pu changer
        case failed      // échec sans rebase en cours → retour possible à l'édition
    }

    @Published private(set) var phase: Phase = .editing
    @Published var steps: [RebaseStep] = []
    /// Nombre de commits récents inclus dans le rebase (base = parent du plus ancien).
    @Published private(set) var count: Int = 0
    /// L'arbre de travail est-il propre ? (Re)calculé au chargement et avant lancement.
    @Published private(set) var treeClean = true
    /// Détail `git status --porcelain` quand l'arbre n'est pas propre (affiché à l'UI).
    @Published private(set) var dirtyStatus = ""
    /// Sortie brute de git (paused / failed / finished) affichée telle quelle.
    @Published private(set) var output = ""
    /// En pause : y a-t-il des conflits (vs simple arrêt sur `edit`) ?
    @Published private(set) var hasConflicts = false
    /// Message de synthèse quand `phase == .finished`.
    @Published private(set) var resultMessage = ""
    /// Vrai quand `phase == .finished` **par complétion** (pas par abandon) : seul cas
    /// où proposer un force-push (le rebase a réellement réécrit l'historique).
    @Published private(set) var completed = false
    /// Push en cours ?
    @Published private(set) var isPushing = false
    /// Résultat du dernier force-push (`nil` = pas encore tenté).
    @Published private(set) var pushResult: String?
    @Published private(set) var pushOK = false

    let repoURL: URL
    /// Branche amont visée par le force-push (ex. `origin/feat/xxx`), ou `nil`.
    let upstream: String?
    /// Historique complet chargé (le plus récent en tête), pour re-découper la plage.
    private let allCommits: [GitCommit]
    /// Nombre max de commits rebasables = ceux propres à la branche (avant d'atteindre
    /// le point de création). Borne le stepper : on ne réécrit jamais un commit partagé
    /// avec la branche de base.
    private let rebaseableCount: Int
    /// Hash du plus ancien commit de la plage ORIGINALE (avant réordonnancement) :
    /// la base du rebase est SON parent, indépendamment des permutations.
    private var originalOldestHash = ""
    /// Dossier temporaire (todo + script d'édition de séquence), nettoyé à la fin.
    private var workspace: URL?

    var maxCount: Int { rebaseableCount }

    /// `initialCount` = nombre de commits récents pré-sélectionnés (ex. clic droit sur
    /// le n-ième commit → n commits). `rebaseableCount` borne la plage aux commits propres
    /// à la branche (défaut : tout l'historique chargé).
    init(repo: URL, commits: [GitCommit], upstream: String?, initialCount: Int? = nil, rebaseableCount: Int? = nil) {
        self.repoURL = repo
        self.allCommits = commits
        self.upstream = upstream
        self.rebaseableCount = max(1, min(rebaseableCount ?? commits.count, commits.count))
        rebuild(count: initialCount ?? min(5, commits.count))
        refreshCleanState()
    }

    // MARK: - Plan

    /// (Re)construit le plan pour les `count` commits les plus récents, du plus
    /// ancien (en haut) au plus récent (en bas) — l'ordre du todo git.
    func rebuild(count: Int) {
        let bounded = max(1, min(count, rebaseableCount))
        self.count = bounded
        let selected = Array(allCommits.prefix(bounded))     // le plus récent en tête
        originalOldestHash = selected.last?.hash ?? ""
        steps = selected.reversed().map { RebaseStep(commit: $0) }  // plus ancien en haut
    }

    /// Message de validation bloquant le lancement, ou `nil` si le plan est valide.
    var validationError: String? {
        if steps.contains(where: { $0.isMerge }) {
            return "La plage contient un commit de fusion — le rebase interactif l'aplatirait. Choisis une base plus récente (moins de commits)."
        }
        let kept = steps.filter { $0.action != .drop }
        if kept.isEmpty {
            return "Toutes les lignes sont en « drop » : rien à rebaser."
        }
        if kept.first?.action.isMeld == true {
            return "La première ligne conservée ne peut pas être « squash »/« fixup » (aucun commit précédent où fusionner)."
        }
        for step in steps where step.action == .reword {
            if step.newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Un « reword » a un message vide (commit \(step.shortHash))."
            }
        }
        return nil
    }

    // MARK: - État de l'arbre

    /// Recalcule `treeClean` / `dirtyStatus` en tâche de fond.
    func refreshCleanState() {
        let repo = repoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = Git.run(["status", "--porcelain"], in: repo)
            let trimmed = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.treeClean = status.ok && trimmed.isEmpty
                self?.dirtyStatus = trimmed
            }
        }
    }

    // MARK: - Lancement

    /// Lance le rebase. Re-vérifie l'arbre propre (garde-fou final) puis exécute
    /// `git rebase -i <base>` avec le todo généré. À appeler après confirmation UI.
    func launch() {
        guard validationError == nil else { return }
        phase = .running
        output = ""

        let repo = repoURL
        let plan = steps
        let oldest = originalOldestHash

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Garde-fou final : refuser si l'arbre n'est pas propre.
            let status = Git.run(["status", "--porcelain"], in: repo)
            let dirty = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !status.ok || !dirty.isEmpty {
                DispatchQueue.main.async {
                    self.treeClean = false
                    self.dirtyStatus = dirty
                    self.output = "L'arbre de travail n'est pas propre. Committez ou remisez vos changements avant de rebaser.\n\n\(dirty)"
                    self.phase = .failed
                }
                return
            }

            // Détermine la base : parent du plus ancien commit de la plage, ou --root.
            let parentRef = oldest + "^"
            let parentCheck = Git.run(["rev-parse", "--verify", "--quiet", parentRef], in: repo)
            let baseArgs = parentCheck.ok ? [parentRef] : ["--root"]

            // Prépare le workspace temporaire (todo + éditeur de séquence).
            guard let env = try? self.prepareWorkspace(plan: plan) else {
                DispatchQueue.main.async {
                    self.output = "Impossible de préparer le rebase (fichiers temporaires)."
                    self.phase = .failed
                }
                return
            }

            let result = Git.run(["rebase", "-i"] + baseArgs, in: repo, extraEnvironment: env)
            self.evaluate(result: result, repo: repo)
        }
    }

    /// Attache le contrôleur à un rebase **déjà en cours** (laissé par une session
    /// précédente) : passe directement en pause pour proposer continue / abort.
    func attachToInProgress() {
        phase = .paused
        let repo = repoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let conflicts = Git.run(["diff", "--name-only", "--diff-filter=U"], in: repo)
            let hasConflicts = !conflicts.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let status = Git.run(["status", "--short", "--branch"], in: repo)
            DispatchQueue.main.async {
                self?.hasConflicts = hasConflicts
                self?.output = Git.sanitize(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Continue / Abort

    func continueRebase() {
        runResumeCommand(["rebase", "--continue"])
    }

    func abortRebase() {
        phase = .running
        let repo = repoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Git.run(["rebase", "--abort"], in: repo)
            DispatchQueue.main.async {
                self?.cleanupWorkspace()
                self?.resultMessage = result.ok
                    ? "Rebase abandonné. Le repo a été restauré à son état initial."
                    : "Échec de l'abandon :\n\(Git.sanitize(result.message))"
                self?.output = Git.sanitize(result.message)
                self?.phase = .finished
            }
        }
    }

    /// Force la mise à jour de la branche amont après un rebase (réécriture d'historique
    /// publié). Utilise **`--force-with-lease`** : refuse d'écraser si l'amont a bougé
    /// de façon inattendue (protège le travail d'autrui). À appeler après confirmation UI.
    func forcePush() {
        guard upstream != nil, !isPushing else { return }
        isPushing = true
        pushResult = nil
        let repo = repoURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Sans argument, pousse la branche courante vers son amont configuré.
            let result = Git.run(["push", "--force-with-lease"], in: repo)
            let message = Git.sanitize(result.message)
            DispatchQueue.main.async {
                self?.pushOK = result.ok
                self?.pushResult = result.ok
                    ? "Branche distante mise à jour (--force-with-lease)."
                    : "Échec du push :\n\(message.isEmpty ? "erreur inconnue" : message)"
                self?.isPushing = false
            }
        }
    }

    private func runResumeCommand(_ args: [String]) {
        phase = .running
        let repo = repoURL
        // GIT_EDITOR=true évite tout éditeur bloquant lors d'un `--continue`.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Git.run(args, in: repo, extraEnvironment: ["GIT_EDITOR": "true"])
            self?.evaluate(result: result, repo: repo)
        }
    }

    /// Analyse le résultat d'un `rebase` / `--continue` : terminé, en pause, ou échec.
    private func evaluate(result: Git.Result, repo: URL) {
        let inProgress = RepoDetail.detectRebaseInProgress(repo: repo)
        let combined = Git.sanitize([result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))

        if inProgress {
            // Arrêt sur `edit` ou conflit : on distingue via les fichiers non fusionnés.
            let conflicts = Git.run(["diff", "--name-only", "--diff-filter=U"], in: repo)
            let hasConflicts = !conflicts.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            DispatchQueue.main.async {
                self.hasConflicts = hasConflicts
                self.output = combined
                self.phase = .paused
            }
        } else if result.ok {
            DispatchQueue.main.async {
                self.cleanupWorkspace()
                self.completed = true
                self.resultMessage = "Rebase terminé. L'historique local a été réécrit."
                self.output = combined
                self.phase = .finished
            }
        } else {
            // Échec sans rebase en cours : git a annulé de lui-même, repo intact.
            DispatchQueue.main.async {
                self.cleanupWorkspace()
                self.output = combined.isEmpty ? "Le rebase a échoué." : combined
                self.phase = .failed
            }
        }
    }

    /// Revient à l'édition du plan après un échec (rien n'est en cours).
    func backToEditing() {
        output = ""
        phase = .editing
        refreshCleanState()
    }

    // MARK: - Workspace temporaire

    /// Écrit le todo et le script `GIT_SEQUENCE_EDITOR`, renvoie l'environnement à
    /// injecter. Le script `cat`e notre todo par-dessus le fichier todo de git (`$1`).
    private func prepareWorkspace(plan: [RebaseStep]) throws -> [String: String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PotofToolkit-rebase-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        workspace = dir

        let todoURL = dir.appendingPathComponent("todo.txt")
        try Self.todoText(from: plan).write(to: todoURL, atomically: true, encoding: .utf8)

        let scriptURL = dir.appendingPathComponent("seq-editor.sh")
        let script = "#!/bin/sh\ncat \(Git.shellSingleQuoted(todoURL.path)) > \"$1\"\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        return [
            // Valeur mise entre apostrophes : robuste à un chemin temp contenant un espace.
            "GIT_SEQUENCE_EDITOR": Git.shellSingleQuoted(scriptURL.path),
            "GIT_EDITOR": "true",
        ]
    }

    /// Génère le texte du todo git à partir du plan (ordre = du haut vers le bas).
    static func todoText(from plan: [RebaseStep]) -> String {
        var lines: [String] = []
        for step in plan {
            let ref = "\(step.id) \(step.originalSubject)"
            switch step.action {
            case .pick:
                lines.append("pick \(ref)")
            case .edit:
                lines.append("edit \(ref)")
            case .squash:
                lines.append("squash \(ref)")
            case .fixup:
                lines.append("fixup \(ref)")
            case .drop:
                lines.append("drop \(ref)")
            case .reword:
                // reword non-interactif : garder le commit puis réécrire son message.
                lines.append("pick \(ref)")
                let message = Git.shellSingleQuoted(step.newMessage)
                lines.append("exec \(Git.executablePath) commit --amend -m \(message)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func cleanupWorkspace() {
        if let dir = workspace {
            try? FileManager.default.removeItem(at: dir)
            workspace = nil
        }
    }
}
