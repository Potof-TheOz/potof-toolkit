import Foundation
import Network

/// Serveur « IDE » d'**une** session Claude : un `NWListener` WebSocket sur
/// `127.0.0.1:<port>` + le fichier `~/.claude/ide/<port>.lock` que `claude` lit
/// pour découvrir le port et le token. Un serveur par session → l'`openDiff` arrive
/// sur le bon socket, donc se route naturellement vers la bonne session.
///
/// Cycle de vie calqué sur le process : `TerminalController` crée le serveur au
/// lancement (avant de spawn le shell, pour injecter le port dans l'env) et l'arrête
/// à la fermeture (supprime le lock). Voir `docs/IDE_BRIDGE.md`.
final class IDEServer {

    let sessionID: UUID
    let workspace: URL
    let token: String
    /// Port réservé (nil si la réservation a échoué → pas d'intégration IDE, la
    /// session tourne quand même, sans diffs).
    let port: UInt16?

    /// Seams UI (fixés par la couche session). `onOpenDiff` nil ⇒ refus par défaut
    /// (valide le tuyau sans écrire de fichier). Lus/écrits sur `main`.
    var onOpenDiff: ((IDEDiffRequest, @escaping (IDEDiffVerdict) -> Void) -> Void)?
    /// Claude ferme un onglet de diff (par `tab_name`) / tous les onglets.
    var onCloseTab: ((String) -> Void)?
    var onCloseAllTabs: (() -> Void)?

    private var listener: NWListener?
    private var connections: [IDEConnection] = []
    private let queue = DispatchQueue(label: "com.potof.toolkit.ide")

    init(sessionID: UUID, workspace: URL) {
        self.sessionID = sessionID
        self.workspace = workspace
        self.token = "potof-" + UUID().uuidString + UUID().uuidString
        self.port = Self.reserveEphemeralPort()
    }

    /// `true` si l'intégration IDE est disponible (port réservé). Décide de
    /// l'injection des variables d'environnement côté `TerminalController`.
    var isAvailable: Bool { port != nil }

    /// Variables à injecter dans l'environnement du shell pour que `claude` se
    /// connecte à CE serveur (et pas à un lock WebStorm : l'env prime sur le scan).
    var environment: [String] {
        guard let port else { return [] }
        return ["CLAUDE_CODE_SSE_PORT=\(port)", "ENABLE_IDE_INTEGRATION=true"]
    }

    func start() {
        guard let port else { return }
        writeLock(port: port)
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] nwc in
                guard let self else { nwc.cancel(); return }
                let conn = IDEConnection(
                    nwc: nwc, token: self.token, workspace: self.workspace,
                    handlers: self.makeHandlers())
                self.connections.append(conn)
                conn.onClose = { [weak self, weak conn] in
                    self?.connections.removeAll { $0 === conn }
                }
                conn.start(queue: self.queue)
            }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { IDELog.log("listener \(port) failed: \(e)") }
            }
            l.start(queue: queue)
            listener = l
            IDELog.log("IDE server prêt sur 127.0.0.1:\(port) (session \(sessionID))")
        } catch {
            IDELog.log("IDE listener erreur: \(error)")
            removeLock(port: port)
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        if let port { removeLock(port: port) }
    }

    /// Handlers passés aux connexions : tout est marshalé sur `main` (les seams sont
    /// lus/écrits par l'UI). Sans `onOpenDiff`, on refuse — le fichier reste intact.
    private func makeHandlers() -> IDEDiffHandlers {
        IDEDiffHandlers(
            openDiff: { [weak self] req, done in
                DispatchQueue.main.async {
                    if let handler = self?.onOpenDiff { handler(req, done) } else { done(.rejected) }
                }
            },
            closeTab: { [weak self] tabName in
                DispatchQueue.main.async { self?.onCloseTab?(tabName) }
            },
            closeAllTabs: { [weak self] in
                DispatchQueue.main.async { self?.onCloseAllTabs?() }
            })
    }

    // MARK: - Lock file

    private func writeLock(port: UInt16) {
        let lock: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": [workspace.path],
            "ideName": Self.ideName,
            "transport": "ws",
            "runningInWindows": false,
            "authToken": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: lock) else { return }
        let url = Self.lockDir.appendingPathComponent("\(port).lock")
        try? FileManager.default.createDirectory(at: Self.lockDir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func removeLock(port: UInt16) {
        try? FileManager.default.removeItem(at: Self.lockDir.appendingPathComponent("\(port).lock"))
    }

    // MARK: - Statique

    static let ideName = "Potof Toolkit"

    static var lockDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ide", isDirectory: true)
    }

    /// Réserve un port éphémère libre : bind à `127.0.0.1:0`, lit le port attribué,
    /// referme. Fenêtre de course minuscule (localhost mono-utilisateur) — acceptable.
    private static func reserveEphemeralPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: got.sin_port)
    }

    /// Supprime les locks Potof orphelins (process mort) au démarrage de l'app —
    /// nettoie ce qu'un crash aurait laissé. Ne touche pas aux locks d'autres IDE.
    static func sweepStaleLocks() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: lockDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ideName"] as? String == ideName,
                  let pid = obj["pid"] as? Int else { continue }
            // kill(pid, 0) échoue (ESRCH) si le process n'existe plus.
            if kill(pid_t(pid), 0) != 0 {
                try? FileManager.default.removeItem(at: url)
                IDELog.log("lock orphelin supprimé: \(url.lastPathComponent)")
            }
        }
    }
}
