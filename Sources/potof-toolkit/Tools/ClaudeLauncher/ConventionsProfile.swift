import Foundation

/// Profil de **conventions maison** injecté dans chaque `CLAUDE.md` généré par la
/// fonction « Initialiser CLAUDE.md ». Stocké dans un fichier markdown local et
/// éditable — `~/Library/Application Support/PotofToolkit/conventions.md`, à côté des
/// notifs et du log IDE (100 % local, cf. CLAUDE.md). Un défaut est écrit au premier
/// accès si le fichier est absent ; l'utilisateur peut ensuite l'éditer librement, et
/// ses règles voyagent alors avec chaque repo initialisé (utile en collab).
enum ConventionsProfile {

    /// `~/Library/Application Support/PotofToolkit/conventions.md`.
    /// Même construction inline que `NotificationChannel`/`IDELog` (pas de helper
    /// partagé : on reste sur le pattern déjà en place dans le repo).
    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PotofToolkit", isDirectory: true)
            .appendingPathComponent("conventions.md", isDirectory: false)
    }

    /// Contenu par défaut, écrit au premier lancement puis édité par l'utilisateur.
    /// **Une règle par ligne** (pas de retour au milieu d'une règle) : `augmentationPrompt()`
    /// ne garde que les puces (`-`, `*` ou `+`) et les aplatit ; un saut de ligne couperait
    /// une règle.
    static let defaultContent = """
    # Conventions maison

    Règles à appliquer et à documenter dans le `CLAUDE.md` de chaque projet, adaptées
    à la stack détectée.

    - Un fichier = une seule fonction ou classe, jamais de fichier fourre-tout.
    - Fichiers courts à responsabilité unique, pas de fonction obèse.
    - Nommage des fichiers en kebab-case quand la techno s'y prête (sinon la convention idiomatique du langage), pour éviter les soucis de casse en collab Windows.
    - Couverture de tests unitaires sur la logique métier.
    """

    /// Écrit le fichier avec le contenu par défaut s'il n'existe pas. **Idempotent** :
    /// ne touche jamais un fichier déjà présent (les éditions de l'utilisateur priment).
    @discardableResult
    static func ensureExists() -> URL {
        let url = fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaultContent.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Lit les conventions courantes (le défaut est matérialisé au besoin). Renvoie
    /// une chaîne vide seulement si la lecture échoue (jamais attendu).
    static func read() -> String {
        ensureExists()
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Message d'augmentation à injecter dans la session `claude`, **après** que
    /// `/init` a écrit le `CLAUDE.md`. Contrainte forte : **une seule ligne logique**
    /// (la TUI valide sur Entrée — cf. le saut de ligne Shift/Option+Entrée), donc on
    /// ne garde que les puces (`-`, `*` ou `+`) et on les aplatit en ` ; `.
    ///
    /// Renvoie **`nil` si aucune règle** n'est trouvée (fichier vidé, ou reformaté sans
    /// puces reconnues) : sans ça, un prompt tronqué « … du projet : » serait envoyé et
    /// `claude` écrirait une section « Conventions » vide ou hallucinée. Le coordinateur
    /// saute alors proprement l'étape d'augmentation.
    static func augmentationPrompt() -> String? {
        let rules = read()
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                // Puce Markdown « - / * / + » SUIVIE d'un blanc. Exiger le blanc écarte les
                // traits horizontaux (`---`, `***`) et l'emphase (`**gras**`) que l'utilisateur
                // peut glisser dans le fichier édité librement, et qui deviendraient sinon des
                // « règles » parasites.
                guard let first = line.first, "-*+".contains(first) else { return nil }
                let afterBullet = line.dropFirst()
                guard let second = afterBullet.first, second.isWhitespace else { return nil }
                let rest = String(afterBullet).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
            .joined(separator: " ; ")
        guard !rules.isEmpty else { return nil }
        return "Ajoute au CLAUDE.md une section « Conventions » reprenant ces règles "
            + "maison, adaptées à la stack détectée du projet : \(rules)"
    }
}
