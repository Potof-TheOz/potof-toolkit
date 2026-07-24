import Foundation
import Combine

/// Pilote la résolution **dans l'app** des conflits laissés par un `pull --rebase` (ou un
/// rebase interactif, ou un merge). S'appuie sur la même mécanique que `RebaseController` :
/// git s'est arrêté, un `rebase-merge`/`MERGE_HEAD` traîne, on résout puis on continue.
///
/// Flux : lister les fichiers `U` → pour chacun, choisir par bloc (nôtre/leur/les deux) ou
/// éditer → écrire + `git add` → quand plus aucun `U`, `git rebase --continue` (ou
/// `git commit --no-edit` pour un merge). **Abandonner** restaure toujours l'état initial.
final class ConflictResolver: ObservableObject {

    /// Chemins encore en conflit (`git diff --diff-filter=U`).
    @Published private(set) var files: [String] = []
    /// Fichier en cours d'édition (choix par bloc).
    @Published var current: ConflictFile?
    @Published private(set) var isBusy = false
    /// Message d'erreur / info à afficher.
    @Published var message: String?
    /// Terminé (succès ou abandon) → la vue se referme.
    @Published private(set) var finished = false

    let repo: URL
    /// Rebase en cours (sinon merge) — détermine la commande de poursuite.
    private var isRebase = true

    /// Appelé (thread principal) à la fin (recharge graphe + statut côté hôte).
    var onFinished: (() -> Void)?

    init(repo: URL) { self.repo = repo }

    /// Toutes les résolutions sont-elles faites (plus aucun fichier `U`) ?
    var allStaged: Bool { files.isEmpty }

    // MARK: - Chargement

    func reload() {
        isBusy = true
        let repo = self.repo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let unmerged = Git.run(["diff", "--name-only", "--diff-filter=U"], in: repo)
            let paths = unmerged.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            let rebase = RepoDetail.detectRebaseInProgress(repo: repo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRebase = rebase
                self.files = paths
                self.isBusy = false
                // Sélectionne le premier fichier non encore chargé.
                if let path = paths.first, self.current == nil || !paths.contains(self.current!.path) {
                    self.select(path)
                } else if paths.isEmpty {
                    self.current = nil
                }
            }
        }
    }

    func select(_ path: String) {
        let url = repo.appendingPathComponent(path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            message = "Lecture impossible : \(path)"
            return
        }
        current = ConflictParser.parse(path: path, content: content)
    }

    // MARK: - Choix

    func setChoice(_ choice: ConflictHunk.Choice, forHunk id: Int) {
        current?.setChoice(choice, forHunk: id)
    }

    /// Applique un même choix à tous les blocs du fichier courant.
    func setAll(_ choice: ConflictHunk.Choice) {
        guard var file = current else { return }
        for hunk in file.hunks { file.setChoice(choice, forHunk: hunk.id) }
        current = file
    }

    // MARK: - Écriture + staging

    /// Écrit le fichier résolu (depuis les choix par bloc) et le `git add`.
    func stageResolved() {
        guard let file = current, let content = file.resolvedContent() else {
            message = "Des blocs restent non résolus."
            return
        }
        write(content, path: file.path)
    }

    /// Écrit un contenu édité manuellement (libre) et le `git add`.
    func stageManual(_ content: String) {
        guard let path = current?.path else { return }
        write(content, path: path)
    }

    private func write(_ content: String, path: String) {
        isBusy = true
        let repo = self.repo
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = repo.appendingPathComponent(path)
            var ok = false
            var msg = ""
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                let add = Git.run(["add", "--", path], in: repo)
                ok = add.ok
                msg = Git.sanitize(add.message)
            } catch {
                msg = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.isBusy = false
                if ok {
                    self?.current = nil
                    self?.reload()
                } else {
                    self?.message = msg.isEmpty ? "Échec du staging de \(path)." : msg
                }
            }
        }
    }

    // MARK: - Poursuite / abandon

    func continueOperation() {
        isBusy = true
        let repo = self.repo
        let rebase = self.isRebase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // GIT_EDITOR=true : pas d'éditeur bloquant (message de rebase / de merge).
            let args = rebase ? ["rebase", "--continue"] : ["commit", "--no-edit"]
            let result = Git.run(args, in: repo, extraEnvironment: ["GIT_EDITOR": "true"])
            let stillInProgress = RepoDetail.detectRebaseInProgress(repo: repo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if stillInProgress {
                    // Étape suivante du rebase → d'autres conflits possibles.
                    self.message = nil
                    self.reload()
                } else if result.ok || !rebase {
                    self.finish()
                } else {
                    self.message = Git.sanitize(result.message)
                }
            }
        }
    }

    func abort() {
        isBusy = true
        let repo = self.repo
        let rebase = self.isRebase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = Git.run(rebase ? ["rebase", "--abort"] : ["merge", "--abort"], in: repo)
            DispatchQueue.main.async { self?.finish() }
        }
    }

    private func finish() {
        finished = true
        onFinished?()
    }
}
