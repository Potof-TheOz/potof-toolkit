import Foundation
import os

/// Pont d'intégration « IDE » de Claude Code.
///
/// Claude Code sait piloter un IDE **en tant que serveur MCP** : l'IDE ouvre un
/// WebSocket sur `127.0.0.1`, publie un fichier `~/.claude/ide/<port>.lock`, et le
/// CLI `claude` s'y connecte (JSON-RPC 2.0) — soit parce qu'on lui a injecté
/// `CLAUDE_CODE_SSE_PORT` (sessions possédées par l'app), soit par **découverte du
/// lock** (agents externes : Superset, n'importe quel terminal du poste ; le
/// matching se fait par préfixe de chemin sur `workspaceFolders`).
/// Quand Claude veut modifier un fichier, il appelle l'outil **`openDiff`** (bloquant)
/// au lieu d'écrire : l'IDE affiche le diff, l'utilisateur accepte/refuse, et l'IDE
/// renvoie `FILE_SAVED` (+ contenu final) / `DIFF_REJECTED`.
///
/// ⚠️ **Contrat vérifié empiriquement contre `claude 2.1.220`** — les formes de
/// réponse exactes et les constantes vivent dans `IDEProtocolContract`, voir aussi
/// `docs/IDE_BRIDGE.md`. Points saillants :
/// - sous-protocole WebSocket exigé : `mcp` (à écho dans la réponse 101) ;
/// - header d'auth : `X-Claude-Code-Ide-Authorization: <authToken du lock>` ;
/// - **`FILE_SAVED` = « l'utilisateur accepte »** → c'est **Claude** qui écrit le
///   fichier ensuite, avec le contenu qu'on lui renvoie. `DIFF_REJECTED` laisse le
///   fichier intact. **Cette app ne touche donc JAMAIS au disque** : elle ne fait
///   que présenter le diff et voter.
///
/// Protocole non-officiel (reverse-engineered) : susceptible de bouger d'une version
/// de `claude` à l'autre. Isolé ici et re-validable avec `--ide-selftest`.

/// Demande d'aperçu de diff reçue via l'outil MCP `openDiff`.
struct IDEDiffRequest: Identifiable {
    /// Identité **locale** de la demande (générée à la réception, pas fournie par
    /// le CLI). Clé de résolution : une même connexion peut avoir **N `openDiff`
    /// en vol** en parallèle (les sous-agents `Task` d'un même `claude` en émettent
    /// concurremment) — sans cette clé, impossible d'apparier un verdict à l'appel
    /// JSON-RPC qui l'attend.
    let id: UUID
    /// Chemin du fichier existant (lu sur disque pour l'« avant »).
    let oldPath: String
    /// Chemin cible (identique à `oldPath` pour une édition en place).
    let newPath: String
    /// Contenu **entier** proposé du fichier (le « après »).
    let newContents: String
    /// Libellé opaque de l'onglet, ex. `"✻ [Claude Code] file.swift (ab12cd) ⧉"`.
    /// Sert de clé d'appariement pour `close_tab`.
    let tabName: String
}

/// Verdict de l'utilisateur sur une demande `openDiff`.
///
/// ⚠️ N'est **plus** un `String` brut : depuis `claude 2.1.220` (vérifié), le contenu
/// renvoyé avec `FILE_SAVED` **devient l'input réel** de l'outil `Edit`/`Write` — donc
/// accepter, c'est renvoyer un contenu, et on peut accepter **en l'ayant modifié**.
/// La traduction en tableau `content` MCP est centralisée dans `IDEProtocolContract`.
enum IDEDiffVerdict {
    /// Accepté : `content` est ce que `claude` écrira (contenu proposé, ou édité par
    /// l'utilisateur). ⚠️ Si `content` est identique à l'ancien fichier, le CLI en
    /// déduit un diff vide et traite ça comme un **refus** (cf. `IDEProtocolContract`).
    case saved(content: String)
    /// Refusé : le fichier reste intact, `claude` l'annonce à l'agent.
    case rejected
}

extension IDEDiffVerdict {
    /// Étiquette courte pour `ide.log`. **Ne journalise pas le contenu** (un fichier
    /// entier n'a rien à faire dans le log), seulement sa taille.
    var logLabel: String {
        switch self {
        case .saved(let content): return "FILE_SAVED (\(content.utf8.count) o)"
        case .rejected:           return "DIFF_REJECTED"
        }
    }
}

/// Callbacks fournis par la couche session à chaque connexion IDE. Regroupés pour
/// garder l'`init` de `IDEConnection` lisible. Tous appelés sur le thread principal.
struct IDEDiffHandlers {
    /// Présente le diff et rappelle avec le verdict. Peut être **asynchrone** : la
    /// complétion n'est invoquée qu'au clic Accepter/Refuser de l'utilisateur.
    let openDiff: (IDEDiffRequest, @escaping (IDEDiffVerdict) -> Void) -> Void
    /// Claude ferme un onglet de diff (par `tab_name`). Sert à fermer un aperçu
    /// encore ouvert si Claude annule (ex. Ctrl-C dans le terminal).
    let closeTab: (String) -> Void
    /// Claude ferme tous les onglets de diff.
    let closeAllTabs: () -> Void

    /// Handler par défaut (Phase 1 / selftest) : refuse tout, ne touche à rien.
    static let rejectingDefault = IDEDiffHandlers(
        openDiff: { _, done in done(.rejected) },
        closeTab: { _ in },
        closeAllTabs: {})
}

/// Journalisation du pont IDE. Va dans `os_log` **et**, toujours, dans un fichier
/// fixe `~/Library/Application Support/PotofToolkit/ide.log` (à côté des notifs) —
/// diagnostic exploitable quel que soit le mode de lancement (bundle ou `swift run`),
/// sans dépendre d'une variable d'env. `POTOF_IDE_LOG_FILE` peut rediriger ailleurs
/// (utilisé par `--ide-selftest`).
enum IDELog {
    private static let logger = Logger(subsystem: "com.potof.toolkit", category: "ide")

    static let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["POTOF_IDE_LOG_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PotofToolkit", isDirectory: true)
            .appendingPathComponent("ide.log", isDirectory: false)
    }()

    /// Repart d'un log vierge à chaque lancement de l'app : son contenu réfère des
    /// sessions mortes (rien n'est persisté), et ça borne sa taille. Même esprit que
    /// le canal de notifications. Appelé au démarrage (pas en `--ide-selftest`).
    static func startSession() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)   // tronque/crée
    }

    static func log(_ message: @autoclosure () -> String) {
        let m = message()
        logger.debug("\(m, privacy: .public)")
        let url = fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url),
              let data = "\(Date()) \(m)\n".data(using: .utf8) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        h.write(data)
    }
}
