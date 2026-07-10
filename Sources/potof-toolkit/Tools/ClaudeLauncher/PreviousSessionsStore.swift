import Foundation
import Combine

/// Source des **sessions Claude passées** affichées dans la section « Précédentes »
/// de la sidebar. Lit (jamais n'écrit) les fichiers `.jsonl` que Claude Code range
/// dans `~/.claude/projects/<dossier-encodé>/`.
///
/// Périmètre : uniquement les sessions dont le `cwd` correspond à un **dossier
/// visible dans la sidebar** (sous-dossiers du root + favoris). Le dossier projet
/// est localisé par **encodage forward** du chemin visible (rapide), puis chaque
/// session est **confirmée par son `cwd`** réel (le nom de dossier encodé peut
/// mentir après un renommage — cf. le bucket historique `claude-launcher` dont le
/// `cwd` est en réalité `potof-toolkit`).
///
/// Non annoté `@MainActor` (comme le reste du projet). Le parsing disque se fait
/// sur une **queue de fond** ; seule la publication de `@Published sessions` revient
/// sur le thread principal. Le cache par `(chemin, mtime)` n'est touché que sur
/// cette queue.
final class PreviousSessionsStore: ObservableObject {
    @Published private(set) var sessions: [PreviousSession] = []

    private let queue = DispatchQueue(label: "org.potof.previous-sessions", qos: .utility)
    /// Cache des champs parsés par fichier, invalidé au changement de `mtime`.
    /// `nil` mémorise aussi un fichier illisible / sans id (évite de re-parser).
    /// Accédé **uniquement** sur `queue`.
    private var cache: [String: (mtime: Date, parsed: ParsedFile?)] = [:]
    /// Jeton de génération (thread principal) : ignore le résultat d'un scan
    /// périmé si un `refresh` plus récent est parti entre-temps.
    private var generation = 0

    /// `~/.claude/projects`.
    static var projectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Nom du dossier projet Claude pour un chemin absolu : `/`, `.` et `_` → `-`.
    /// Contrat non-officiel vérifié empiriquement sur l'ensemble des projets.
    static func projectDirName(forPath path: String) -> String {
        String(path.map { ($0 == "/" || $0 == "." || $0 == "_") ? "-" : $0 })
    }

    // MARK: - Rafraîchissement

    /// (Re)construit la liste pour les `folders` visibles. Idempotent, peu coûteux
    /// grâce au cache `mtime` ; à appeler sur les mêmes événements discrets que le
    /// scan des dossiers (apparition, retour au premier plan, changement de liste).
    func refresh(folders: [FolderItem]) {
        generation += 1
        let gen = generation
        // On capture des valeurs immuables (chemin résolu + url) pour la queue.
        let targets = folders.map { (resolved: SessionStore.normalized($0.url.path), url: $0.url) }
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.scan(targets: targets)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }   // un refresh plus récent gagne
                self.sessions = found
            }
        }
    }

    // MARK: - Scan (queue de fond)

    private func scan(targets: [(resolved: String, url: URL)]) -> [PreviousSession] {
        let fm = FileManager.default
        var result: [PreviousSession] = []
        var seenIDs = Set<String>()          // dédup (2 dossiers → même bucket : rare)
        var liveKeys = Set<String>()         // fichiers encore présents → purge du cache
        var scannedDirs = Set<String>()      // ne pas scanner 2× le même bucket

        for target in targets {
            let dirName = Self.projectDirName(forPath: target.url.path)
            guard scannedDirs.insert(dirName).inserted else { continue }
            let dir = Self.projectsRoot.appendingPathComponent(dirName, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let path = file.path
                liveKeys.insert(path)
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                let parsed: ParsedFile?
                if let hit = cache[path], hit.mtime == mtime {
                    parsed = hit.parsed
                } else {
                    parsed = Self.parse(file: file)
                    cache[path] = (mtime, parsed)
                }
                guard let p = parsed, seenIDs.insert(p.id).inserted else { continue }

                // Confirmation d'appartenance : si un `cwd` a été trouvé, il doit
                // matcher le dossier visible (rejette un bucket « mixte ») ; sinon
                // (session sans `cwd`) on fait confiance au bucket forward-encodé.
                let folderURL: URL
                if let cwd = p.cwd {
                    guard SessionStore.normalized(cwd) == target.resolved else { continue }
                    folderURL = URL(fileURLWithPath: cwd)
                } else {
                    folderURL = target.url
                }

                let title = p.title.isEmpty ? folderURL.lastPathComponent : p.title
                result.append(PreviousSession(
                    id: p.id, folderURL: folderURL, title: title,
                    lastUsed: mtime, gitBranch: p.gitBranch))
            }
        }

        cache = cache.filter { liveKeys.contains($0.key) }   // purge les fichiers disparus
        return result.sorted { $0.lastUsed > $1.lastUsed }
    }

    // MARK: - Parsing d'un fichier

    /// Champs bruts extraits d'un `.jsonl` — indépendants du dossier cible, donc
    /// cachables tels quels.
    private struct ParsedFile {
        let id: String
        let cwd: String?
        let title: String
        let gitBranch: String
    }

    /// Ligne JSONL minimale : seuls les champs qui nous intéressent.
    private struct Line: Decodable {
        let cwd: String?
        let gitBranch: String?
        let aiTitle: String?
        let lastPrompt: String?
    }

    /// Extrait id + `cwd` + titre d'un fichier en **une passe**. Optimisation :
    /// on ne décode en JSON que les lignes qui *contiennent* la clé recherchée
    /// (les grosses lignes `assistant` sont ignorées une fois le `cwd` trouvé).
    /// Le **dernier** `aiTitle` gagne (le titre est réécrit au fil de la session).
    private static func parse(file: URL) -> ParsedFile? {
        let id = file.deletingPathExtension().lastPathComponent
        guard !id.isEmpty, let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        var cwd: String?
        var gitBranch = ""
        var aiTitle: String?
        var lastPrompt: String?

        content.enumerateLines { line, _ in
            if cwd == nil, line.contains("\"cwd\""), let d = Self.decode(line), let c = d.cwd {
                cwd = c
                if let b = d.gitBranch { gitBranch = b }
            }
            if line.contains("\"aiTitle\""), let d = Self.decode(line),
               let t = d.aiTitle, !t.isEmpty {
                aiTitle = t                       // dernier gagne
            }
            if line.contains("\"lastPrompt\""), let d = Self.decode(line),
               let p = d.lastPrompt, !p.isEmpty {
                lastPrompt = p                    // dernier gagne
            }
        }

        let title: String
        if let t = aiTitle { title = t }
        else if let p = lastPrompt { title = String(p.prefix(80)) }
        else { title = "" }

        return ParsedFile(id: id, cwd: cwd, title: title, gitBranch: gitBranch)
    }

    private static func decode(_ line: String) -> Line? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Line.self, from: data)
    }
}
