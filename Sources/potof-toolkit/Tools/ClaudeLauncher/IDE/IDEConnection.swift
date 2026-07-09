import Foundation
import Network
import CryptoKit

/// Une connexion WebSocket entrante d'un `claude` (client MCP).
///
/// Fait à la main : handshake HTTP/WebSocket (RFC 6455) puis framing, afin de
/// pouvoir **lire le header d'auth** et **écho le sous-protocole `mcp`** — deux
/// choses que l'API haut niveau `NWProtocolWebSocket` ne permet pas côté serveur.
/// Toutes les E/S passent par la file série fournie par `IDEServer` (sérialisation
/// des écritures de frames).
final class IDEConnection {

    private let conn: NWConnection
    private let expectedToken: String
    private let workspace: URL
    /// Seam vers l'UI (présenter le diff / fermer les onglets). `IDEServer` fournit
    /// des handlers qui marshalent sur `main`. Sans UI branchée : refus d'office.
    private let handlers: IDEDiffHandlers

    var onClose: (() -> Void)?

    private var queue: DispatchQueue = .main
    private var didHandshake = false
    private var closed = false
    private var inbound = Data()
    private var fragment = Data()

    init(nwc: NWConnection, token: String, workspace: URL, handlers: IDEDiffHandlers) {
        self.conn = nwc
        self.expectedToken = token
        self.workspace = workspace
        self.handlers = handlers
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func cancel() { conn.cancel() }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    // MARK: - Réception

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                if self.didHandshake { self.parseFrames() } else { self.tryHandshake() }
            }
            if error != nil || isComplete { self.conn.cancel(); return }
            self.receive()
        }
    }

    // MARK: - Handshake HTTP → WebSocket

    private func tryHandshake() {
        guard let sep = inbound.range(of: Data("\r\n\r\n".utf8)) else { return } // en-têtes incomplets
        let headerData = inbound.subdata(in: inbound.startIndex..<sep.lowerBound)
        inbound.removeSubrange(inbound.startIndex..<sep.upperBound)
        guard let raw = String(data: headerData, encoding: .utf8) else { conn.cancel(); return }

        var headers: [String: String] = [:]
        for line in raw.split(separator: "\r\n").dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }

        // Auth : on **valide** le token (le binding 127.0.0.1 reste la barrière
        // principale ; ceci est la ceinture + bretelles). Refus → coupe.
        guard headers["x-claude-code-ide-authorization"] == expectedToken else {
            IDELog.log("connexion refusée : token d'auth absent ou invalide")
            sendRaw("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n") { self.conn.cancel() }
            return
        }
        guard let key = headers["sec-websocket-key"] else { conn.cancel(); return }

        let accept = Data(Insecure.SHA1.hash(
            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var resp = "HTTP/1.1 101 Switching Protocols\r\n"
        resp += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        resp += "Sec-WebSocket-Accept: \(accept)\r\n"
        // Claude exige le sous-protocole `mcp` ; on renvoie le premier proposé.
        if let proto = headers["sec-websocket-protocol"]?
            .split(separator: ",").first?.trimmingCharacters(in: .whitespaces) {
            resp += "Sec-WebSocket-Protocol: \(proto)\r\n"
        }
        resp += "\r\n"
        sendRaw(resp)
        didHandshake = true
        IDELog.log("handshake WebSocket OK — connexion IDE établie")
        if !inbound.isEmpty { parseFrames() }
    }

    // MARK: - Frames RFC 6455

    private func parseFrames() {
        while true {
            let bytes = [UInt8](inbound)
            guard bytes.count >= 2 else { return }
            let fin = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var len = Int(bytes[1] & 0x7F)
            var off = 2
            if len == 126 {
                guard bytes.count >= 4 else { return }
                len = Int(bytes[2]) << 8 | Int(bytes[3]); off = 4
            } else if len == 127 {
                guard bytes.count >= 10 else { return }
                len = 0; for i in 2..<10 { len = len << 8 | Int(bytes[i]) }; off = 10
            }
            var mask = [UInt8](repeating: 0, count: 4)
            if masked {
                guard bytes.count >= off + 4 else { return }
                for i in 0..<4 { mask[i] = bytes[off + i] }
                off += 4
            }
            guard bytes.count >= off + len else { return } // payload incomplet
            var payload = [UInt8](bytes[off..<off + len])
            if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            inbound.removeSubrange(inbound.startIndex..<inbound.index(inbound.startIndex, offsetBy: off + len))
            handleFrame(fin: fin, opcode: opcode, payload: Data(payload))
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x8: sendFrame(opcode: 0x8, payload: payload) { self.conn.cancel() }  // close
        case 0x9: sendFrame(opcode: 0xA, payload: payload)                          // ping → pong
        case 0xA: break                                                             // pong
        case 0x0: fragment.append(payload); if fin { dispatch(fragment); fragment.removeAll() }
        case 0x1, 0x2: if fin { dispatch(payload) } else { fragment = payload }
        default: break
        }
    }

    // MARK: - Écriture

    private func sendRaw(_ s: String, then done: (() -> Void)? = nil) {
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in done?() })
    }

    private func sendFrame(opcode: UInt8, payload: Data, then done: (() -> Void)? = nil) {
        var frame = Data([0x80 | opcode])            // FIN + opcode ; serveur→client non masqué
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126); frame.append(UInt8(n >> 8 & 0xFF)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(n >> i & 0xFF)) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in done?() })
    }

    private func sendText(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    // MARK: - JSON-RPC 2.0 / MCP

    private func dispatch(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id = obj["id"]
        guard let method = obj["method"] as? String else { return } // réponse à un de nos appels → ignore

        switch method {
        case "initialize":
            // On écho la version protocole du client (plus sûr que la figer).
            let client = (obj["params"] as? [String: Any])?["protocolVersion"] as? String
            reply(id: id, result: [
                "protocolVersion": client ?? "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "potof-toolkit-ide", "version": "1.0"],
            ])
        case "notifications/initialized", "initialized", "ide_connected":
            break // notifications (sans id) : rien à répondre
        case "tools/list":
            reply(id: id, result: ["tools": Self.toolDefs])
        case "tools/call":
            handleToolCall(id: id, params: obj["params"] as? [String: Any] ?? [:])
        default:
            if id != nil { reply(id: id, result: [:]) }
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "openDiff":
            let req = IDEDiffRequest(
                oldPath: args["old_file_path"] as? String ?? "",
                newPath: args["new_file_path"] as? String ?? "",
                newContents: args["new_file_contents"] as? String ?? "",
                tabName: args["tab_name"] as? String ?? "")
            IDELog.log("openDiff reçu : \(req.tabName)")
            // Bloquant : on ne répond qu'une fois le verdict connu. La complétion
            // peut arriver sur n'importe quel thread → on re-sérialise l'envoi.
            handlers.openDiff(req) { [weak self] verdict in
                guard let self else { return }
                self.queue.async {
                    IDELog.log("openDiff → \(verdict.rawValue)")
                    self.replyToolText(id: id, text: verdict.rawValue)
                }
            }
        case "getWorkspaceFolders":
            replyToolText(id: id, text: Self.jsonString([
                "folders": [["name": workspace.lastPathComponent,
                             "uri": "file://\(workspace.path)",
                             "path": workspace.path]],
                "rootPath": workspace.path,
            ]))
        case "getOpenEditors":
            replyToolText(id: id, text: #"{"tabs":[]}"#)
        case "getCurrentSelection", "getLatestSelection":
            replyToolText(id: id, text: #"{"success":false,"message":"no selection"}"#)
        case "getDiagnostics":
            replyToolText(id: id, text: "[]")
        case "close_tab":
            handlers.closeTab(args["tab_name"] as? String ?? "")
            replyToolText(id: id, text: "TAB_CLOSED")
        case "closeAllDiffTabs":
            handlers.closeAllTabs()
            replyToolText(id: id, text: "CLOSED_0_DIFF_TABS")
        default:
            replyToolText(id: id, text: "OK")
        }
    }

    private func reply(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        sendText(str)
    }

    private func replyToolText(id: Any?, text: String) {
        reply(id: id, result: ["content": [["type": "text", "text": text]]])
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Outils exposés au CLI. Seul `openDiff` est « actif » ; les autres sont des
    /// stubs neutres (Claude les consomme pour du contexte, pas critiques).
    private static let toolDefs: [[String: Any]] = [
        ["name": "openDiff", "description": "Open a diff for approval",
         "inputSchema": ["type": "object",
                         "properties": ["old_file_path": ["type": "string"],
                                        "new_file_path": ["type": "string"],
                                        "new_file_contents": ["type": "string"],
                                        "tab_name": ["type": "string"]],
                         "required": ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]]],
        ["name": "getDiagnostics", "description": "Get language diagnostics",
         "inputSchema": ["type": "object", "properties": ["uri": ["type": "string"]]]],
        ["name": "getWorkspaceFolders", "description": "Get workspace folders",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "getOpenEditors", "description": "Get open editors",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "getCurrentSelection", "description": "Get current selection",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "close_tab", "description": "Close a tab",
         "inputSchema": ["type": "object", "properties": ["tab_name": ["type": "string"]],
                         "required": ["tab_name"]]],
        ["name": "closeAllDiffTabs", "description": "Close all diff tabs",
         "inputSchema": ["type": "object", "properties": [:]]],
    ]
}
