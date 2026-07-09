import Foundation
import os

/// Pont d'intégration « IDE » de Claude Code.
///
/// Claude Code sait piloter un IDE **en tant que serveur MCP** : l'IDE ouvre un
/// WebSocket sur `127.0.0.1`, publie un fichier `~/.claude/ide/<port>.lock`, et le
/// CLI `claude` s'y connecte (JSON-RPC 2.0) dès qu'on lui injecte
/// `CLAUDE_CODE_SSE_PORT` + `ENABLE_IDE_INTEGRATION` dans l'environnement du terminal.
/// Quand Claude veut modifier un fichier, il appelle l'outil **`openDiff`** (bloquant)
/// au lieu d'écrire : l'IDE affiche le diff, l'utilisateur accepte/refuse, et l'IDE
/// renvoie `FILE_SAVED` / `DIFF_REJECTED`.
///
/// ⚠️ **Contrat vérifié empiriquement** (spike, `claude 2.1.205`) — voir
/// `docs/IDE_BRIDGE.md`. Points saillants :
/// - sous-protocole WebSocket exigé : `mcp` (à écho dans la réponse 101) ;
/// - header d'auth : `X-Claude-Code-Ide-Authorization: <authToken du lock>` ;
/// - **`FILE_SAVED` = « l'utilisateur accepte »** → c'est **Claude** qui écrit le
///   fichier ensuite. `DIFF_REJECTED` laisse le fichier intact. **Cette app ne
///   touche donc JAMAIS au disque** : elle ne fait que présenter le diff et voter.
///
/// Protocole non-officiel (reverse-engineered) : susceptible de bouger d'une version
/// de `claude` à l'autre. Isolé ici et re-validable avec `--ide-selftest`.

/// Demande d'aperçu de diff reçue via l'outil MCP `openDiff`.
struct IDEDiffRequest {
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

/// Verdict de l'utilisateur, renvoyé tel quel comme texte de résultat MCP.
enum IDEDiffVerdict: String {
    case saved = "FILE_SAVED"
    case rejected = "DIFF_REJECTED"
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
