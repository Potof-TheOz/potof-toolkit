import Foundation

/// Implémentation des actions git d'écriture (contrat `WorkingCopyServicing`).
///
/// Tout passe par `Git.run` (shell-out vers `/usr/bin/git`, `GIT_TERMINAL_PROMPT=0`). Les
/// arguments sont passés **tels quels** au process (pas de shell), donc **aucun échappement**
/// à faire sur les chemins ou messages. Méthodes **bloquantes** : appelées hors thread
/// principal par `WorkingCopyStore`.
struct GitWorkingActions: WorkingCopyServicing {

    func stage(path: String, in repo: URL) -> GitActionResult {
        // `-A` couvre modif / ajout / suppression du chemin ciblé.
        wrap(Git.run(["add", "-A", "--", path], in: repo))
    }

    func unstage(path: String, in repo: URL) -> GitActionResult {
        let restore = Git.run(["restore", "--staged", "--", path], in: repo)
        if restore.ok { return .success }
        // Fallback (git ancien, ou cas particuliers) : reset de l'entrée d'index.
        return wrap(Git.run(["reset", "-q", "--", path], in: repo))
    }

    func discard(file: FileStatus, in repo: URL) -> GitActionResult {
        if file.isUntracked {
            // Non suivi : aucune version de référence → on supprime le fichier du disque.
            let url = repo.appendingPathComponent(file.path)
            do {
                try FileManager.default.removeItem(at: url)
                return .success
            } catch {
                return GitActionResult(ok: false, message: "Suppression impossible : \(error.localizedDescription)")
            }
        }
        // Suivi : restaure la copie de travail depuis l'index (annule les modifs non indexées).
        return wrap(Git.run(["restore", "--", file.path], in: repo))
    }

    func stageAll(in repo: URL) -> GitActionResult {
        wrap(Git.run(["add", "-A"], in: repo))
    }

    func unstageAll(in repo: URL) -> GitActionResult {
        wrap(Git.run(["reset", "-q"], in: repo))
    }

    func commit(subject: String, body: String, in repo: URL) -> GitActionResult {
        var args = ["commit", "-m", subject]
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty { args += ["-m", trimmedBody] }
        return wrap(Git.run(args, in: repo))
    }

    func push(in repo: URL, setUpstreamBranch: String?) -> GitActionResult {
        let args: [String]
        if let branch = setUpstreamBranch {
            args = ["push", "-u", "origin", branch]
        } else {
            args = ["push"]
        }
        return wrap(Git.run(args, in: repo))
    }

    func pullRebase(in repo: URL) -> GitActionResult {
        // GIT_EDITOR=true : pas d'éditeur bloquant. Un conflit laisse un rebase en pause
        // (détecté ailleurs) → écran de résolution.
        wrap(Git.run(["pull", "--rebase"], in: repo, extraEnvironment: ["GIT_EDITOR": "true"]))
    }

    func fetch(in repo: URL) -> GitActionResult {
        wrap(Git.run(["fetch"], in: repo))
    }

    func applyPatch(_ patch: String, in repo: URL, cached: Bool, reverse: Bool) -> GitActionResult {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PotofToolkit-patch-\(UUID().uuidString).diff")
        do {
            try patch.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return GitActionResult(ok: false, message: "Écriture du patch impossible : \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tmp) }

        var args = ["apply"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append(tmp.path)
        return wrap(Git.run(args, in: repo))
    }

    /// Traduit un `Git.Result` en `GitActionResult` (message nettoyé des séquences ANSI).
    private func wrap(_ r: Git.Result) -> GitActionResult {
        GitActionResult(ok: r.ok, message: Git.sanitize(r.message))
    }
}
