import Foundation

/// Une session Claude **passée** (historique), reconstruite depuis le JSONL que
/// Claude Code écrit dans `~/.claude/projects/<dossier-encodé>/<sessionId>.jsonl`.
///
/// Contrairement à `Session` (possédée, process vivant), c'est une entrée en
/// **lecture seule** : un clic la **reprend** (`claude --resume <id>`), ce qui
/// crée alors une nouvelle `Session` possédée. Contrat non-officiel avec le
/// stockage de Claude, vérifié empiriquement — voir `docs/SESSIONS.md`.
struct PreviousSession: Identifiable, Hashable {
    /// Identifiant de conversation Claude = **nom du fichier `.jsonl`** (UUID sous
    /// forme de chaîne). C'est la clé passée à `claude --resume`.
    let id: String
    /// Dossier de travail réel de la session — le champ `cwd` **lu dans le
    /// fichier** (et non le nom de dossier encodé, qui peut mentir après un
    /// renommage). Sert aussi à confirmer l'appartenance à un dossier visible.
    let folderURL: URL
    /// Titre lisible : dernier `aiTitle` du JSONL, à défaut `lastPrompt` tronqué,
    /// à défaut le nom du dossier.
    let title: String
    /// Dernière activité = date de modification du fichier (`mtime`). Gratuit
    /// (pas de lecture) et suffisant pour un tri anti-chronologique.
    let lastUsed: Date
    /// Branche git au moment de la session (peut être vide).
    let gitBranch: String

    var folderName: String { folderURL.lastPathComponent }
}
