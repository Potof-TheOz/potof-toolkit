import Foundation
import Network
import CryptoKit

/// Une connexion WebSocket entrante d'un `claude` (client MCP).
///
/// Fait à la main : handshake HTTP/WebSocket (RFC 6455) puis framing, afin de
/// pouvoir **lire le header d'auth** et **écho le sous-protocole `mcp`** — deux
/// choses que l'API haut niveau `NWProtocolWebSocket` ne permet pas côté serveur.
///
/// **Modèle de thread** : toute la machine d'état (buffers de réception, demandes en
/// vol, drapeau de fermeture) vit sur la file série fournie par `IDEServer` / `IDEHost`.
/// Les callbacks `NWConnection` y arrivent déjà ; les verdicts venus de l'UI y sont
/// **re-marshalés** avant d'émettre quoi que ce soit. C'est ce qui sérialise les
/// écritures de frames sans le moindre verrou. Les seams (`onHandshake`, `onClientPID`,
/// `onClientHello`, `onClose`) sont donc appelés **sur cette file** : c'est à
/// l'appelant de repasser sur `main` s'il touche de l'UI.
///
/// ⚠️ **Une connexion = N `openDiff` en vol.** Les sous-agents `Task` d'un même
/// `claude` émettent des appels concurrents (défaut D3 du plan) : n'en mémoriser qu'un
/// seul, c'est en laisser d'autres sans réponse. Or `openDiff` est **bloquant** côté
/// CLI — une demande sans réponse fige un agent indéfiniment. D'où l'invariant central
/// de ce fichier :
///
/// > toute demande entrée dans `inFlight` en sort par **exactement une** résolution —
/// > verdict de l'utilisateur, `close_tab`/`closeAllDiffTabs`, ou purge à la fermeture
/// > (et dans ce dernier cas c'est l'UI qu'on débarrasse, le socket étant mort).
final class IDEConnection {

    private let conn: NWConnection
    private let expectedToken: String
    /// Dossier annoncé à l'agent par `getWorkspaceFolders`.
    ///
    /// **Mutable** parce que l'hôte global ne le connaît pas à la connexion : son lock
    /// couvre tout `$HOME`, mais l'espace de travail réel de l'agent est son **cwd**
    /// (typiquement un worktree Superset). Annoncer `$HOME` induirait `claude` en erreur
    /// sur la racine de son projet. `IDEHost` affine donc cette valeur dès que
    /// `ide_connected {pid}` a permis de résoudre le cwd (cf. `IDEClientIdentity`).
    /// Pour une session possédée (`IDEServer`), le dossier est exact dès le départ.
    ///
    /// Écrit depuis `main`, lu depuis la file de la connexion : `atomic` par
    /// construction (une `URL` est une valeur, et une lecture décalée d'un instant
    /// n'annonce qu'un périmètre plus large — jamais un mauvais projet).
    private var workspace: URL
    /// Seam vers l'UI (présenter le diff / fermer les onglets). `IDEServer` / `IDEHost`
    /// fournissent des handlers qui marshalent sur `main`. Sans UI branchée : refus d'office.
    private let handlers: IDEDiffHandlers

    var onClose: (() -> Void)?
    /// Handshake WebSocket réussi = `claude` est connecté (donc booté, après un
    /// éventuel prompt « trust this folder »). Signal robuste pour seeder `/init`.
    var onHandshake: (() -> Void)?
    /// pid du process `claude`, reçu via la notification `ide_connected`.
    var onClientPID: ((Int32) -> Void)?
    /// `clientInfo` de `initialize` : (name, version). Alimente l'empreinte de version (T8).
    var onClientHello: ((String?, String?) -> Void)?

    private var queue: DispatchQueue = .main
    private var didHandshake = false
    private var closed = false
    private var inbound = Data()
    private var fragment = Data()

    // MARK: - Demandes `openDiff` en vol

    /// Un `openDiff` en attente de verdict. On mémorise le strict nécessaire pour
    /// (a) répondre à l'appel bloquant, (b) l'apparier à un `close_tab`, (c) journaliser
    /// une durée d'attente — c'est le seul indicateur qui trahit un agent oublié.
    private struct InFlightDiff {
        /// `id` de la requête JSON-RPC `tools/call` à laquelle il faudra répondre.
        /// Type `Any?` assumé : la spec JSON-RPC autorise nombre **ou** chaîne, et une
        /// réponse dont l'`id` a changé de type n'est appariée par personne. On le
        /// ré-écho donc **tel quel**, sans normalisation.
        let rpcID: Any?
        /// Libellé d'onglet fourni par le CLI : unique clé d'appariement d'un `close_tab`.
        let tabName: String
        let receivedAt: Date
    }

    /// `requestID` (UUID **local** de l'`IDEDiffRequest`) → appel JSON-RPC en attente.
    /// Le CLI ne fournit aucune identité de demande et son `id` JSON-RPC ne descend pas
    /// jusqu'à l'UI : cet UUID est le seul fil qui relie un clic « Accepter » à l'appel
    /// précis qu'il débloque. Accédé **uniquement** depuis `queue`.
    private var inFlight: [UUID: InFlightDiff] = [:]

    // MARK: - Bornes de durcissement du framing

    /// Borne haute d'un message applicatif (frame unique **ou** fragments réassemblés).
    /// `openDiff` transporte un fichier entier, donc il faut de la marge — mais un pair
    /// qui annonce 2^60 octets ne doit pas nous faire bufferiser jusqu'à l'épuisement
    /// mémoire. 64 Mo : très largement au-dessus du plus gros source plausible.
    private static let maxMessageBytes = 64 << 20

    /// Plafond du buffer de réception avant qu'une frame complète n'en sorte. Le
    /// message maximal + une entête de framing (14 o au pire : 2 + 8 de longueur
    /// + 4 de masque), arrondi : au-delà on nous alimente sans jamais former de frame.
    private static let maxBufferedBytes = maxMessageBytes + 1024

    /// Borne des en-têtes HTTP du handshake. Au-delà, ce n'est pas un client Claude qui
    /// parle (ou pas un handshake du tout) → couper plutôt qu'accumuler.
    private static let maxHandshakeBytes = 64 << 10

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

    /// Affine le dossier annoncé par `getWorkspaceFolders` une fois le cwd de l'agent
    /// connu (cf. `workspace`). Appelée depuis `main` par `IDEHost`.
    func updateWorkspace(_ url: URL) { workspace = url }

    /// Fin de vie de la connexion (échec, annulation, pair parti). Appelée sur la file
    /// de la connexion via `stateUpdateHandler`, donc jamais concurremment du parsing.
    ///
    /// **Purge obligatoire.** Plus personne au bout du socket pour lire nos réponses,
    /// mais l'UI, elle, affiche peut-être encore N demandes de ce client : sans purge,
    /// la file de revue se remplirait de fantômes que l'utilisateur validerait dans le
    /// vide. On fait donc retirer chaque aperçu resté en vol via `handlers.closeTab`,
    /// que `DiffReviewCenter` traduit en `.rejected` (règle du centre : toute demande
    /// retirée sans décision explicite part en refus).
    ///
    /// Ordre **non négociable** : vider `inFlight` **avant** de notifier l'UI. La
    /// complétion que ce retrait déclenche revient ici même (re-marshalée sur la file)
    /// et doit tomber sur la garde d'idempotence de `completeDiff` — pas tenter un
    /// `send` sur un socket clos.
    private func finish() {
        guard !closed else { return }
        closed = true
        let orphans = inFlight
        inFlight.removeAll()
        if !orphans.isEmpty {
            IDELog.log("connexion fermée : \(orphans.count) demande(s) en vol purgée(s) côté UI")
            for entry in orphans.values { handlers.closeTab(entry.tabName) }
        }
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
        guard let sep = inbound.range(of: Data("\r\n\r\n".utf8)) else {
            // En-têtes incomplets : on attend la suite — sauf si le buffer enfle sans
            // jamais produire la ligne vide de fin (pair muet ou hostile) → on coupe.
            if inbound.count > Self.maxHandshakeBytes {
                failProtocol("en-têtes de handshake > \(Self.maxHandshakeBytes) o sans fin d'en-tête")
            }
            return
        }
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
        // principale ; ceci est la ceinture + bretelles). Refus → coupe. Le périmètre
        // `$HOME` de l'hôte global élargit la surface : n'importe quel process local
        // peut frapper à la porte, seul ce token l'arrête. Ne jamais le journaliser.
        guard headers[IDEProtocolContract.authHeaderLowercased] == expectedToken else {
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
        // Claude exige le sous-protocole `mcp` (cf. `IDEProtocolContract`) ; on
        // renvoie le premier proposé, ce qui l'écho tel quel.
        if let proto = headers["sec-websocket-protocol"]?
            .split(separator: ",").first?.trimmingCharacters(in: .whitespaces) {
            resp += "Sec-WebSocket-Protocol: \(proto)\r\n"
        }
        resp += "\r\n"
        sendRaw(resp)
        didHandshake = true
        IDELog.log("handshake WebSocket OK — connexion IDE établie")
        onHandshake?()
        if !inbound.isEmpty { parseFrames() }
    }

    // MARK: - Frames RFC 6455

    /// Découpe le buffer en frames. Sort de la boucle dès qu'il manque des octets ; on
    /// travaille **en place** sur `inbound` (indices relatifs à `startIndex`, qui se
    /// déplace au fur et à mesure des `removeSubrange`) plutôt que de recopier tout le
    /// buffer en `[UInt8]` à chaque tour — sur un `openDiff` de plusieurs Mo la
    /// différence n'est pas cosmétique.
    private func parseFrames() {
        while !closed {
            let base = inbound.startIndex
            let available = inbound.count
            guard available >= 2 else { break }
            let b0 = inbound[base]
            let b1 = inbound[base + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7F)
            var off = 2
            if len == 126 {
                guard available >= 4 else { break }
                len = Int(inbound[base + 2]) << 8 | Int(inbound[base + 3]); off = 4
            } else if len == 127 {
                guard available >= 10 else { break }
                // RFC 6455 §5.2 : sur une longueur 64 bits, le bit de poids fort **doit**
                // être 0. Sans ce test, l'accumulation `len << 8 | …` déborde `Int` et
                // produit une longueur **négative** : tous les `guard` de taille en aval
                // sautent d'un coup, et `inbound[start ..< start + len]` part en vrille.
                guard inbound[base + 2] & 0x80 == 0 else {
                    failProtocol("longueur de frame 64 bits invalide (bit de poids fort posé)")
                    return
                }
                var wide: UInt64 = 0
                for i in 2..<10 { wide = wide << 8 | UInt64(inbound[base + i]) }
                guard wide <= UInt64(Self.maxMessageBytes) else {
                    failProtocol("frame annoncée à \(wide) o > plafond \(Self.maxMessageBytes) o")
                    return
                }
                len = Int(wide); off = 10
            }
            guard len <= Self.maxMessageBytes else {
                failProtocol("frame annoncée à \(len) o > plafond \(Self.maxMessageBytes) o")
                return
            }
            // RFC 6455 §5.5 : une frame de contrôle (opcode ≥ 0x8) porte au plus 125
            // octets et n'est jamais fragmentée. Un pair conforme ne viole jamais ça ;
            // le comportement nominal est donc intact, on ne coupe que du hors-contrat.
            guard opcode < 0x8 || (len <= 125 && fin) else {
                failProtocol("frame de contrôle invalide (opcode \(opcode), len \(len), fin \(fin))")
                return
            }
            var mask = [UInt8](repeating: 0, count: 4)
            if masked {
                guard available >= off + 4 else { break }
                for i in 0..<4 { mask[i] = inbound[base + off + i] }
                off += 4
            }
            guard available >= off + len else { break } // payload incomplet
            let start = base + off
            var payload = [UInt8](inbound[start..<start + len])
            if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            inbound.removeSubrange(base..<start + len)
            guard handleFrame(fin: fin, opcode: opcode, payload: Data(payload)) else { return }
        }
        // Garde anti-accumulation : si on est sorti de la boucle faute d'octets alors que
        // le buffer dépasse déjà le plafond, c'est qu'aucune frame complète n'en sortira
        // jamais (longueur mensongère, flux qui n'est pas du WebSocket…). On coupe au
        // lieu de gonfler indéfiniment.
        if !closed && inbound.count > Self.maxBufferedBytes {
            failProtocol("buffer de réception à \(inbound.count) o sans frame complète")
        }
    }

    /// Traite une frame complète. Renvoie `false` quand il ne faut **plus rien parser**
    /// derrière (frame de close reçue, ou violation de contrat : la connexion se ferme).
    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) -> Bool {
        switch opcode {
        case 0x8:                                                       // close
            sendFrame(opcode: 0x8, payload: payload) { self.conn.cancel() }
            return false
        case 0x9: sendFrame(opcode: 0xA, payload: payload)              // ping → pong
        case 0xA: break                                                 // pong
        case 0x0:                                                       // continuation
            guard fragment.count + payload.count <= Self.maxMessageBytes else {
                failProtocol("message fragmenté > plafond \(Self.maxMessageBytes) o")
                return false
            }
            fragment.append(payload)
            if fin { dispatch(fragment); fragment.removeAll() }
        case 0x1, 0x2: if fin { dispatch(payload) } else { fragment = payload }
        default: break
        }
        return true
    }

    /// Coupe la connexion sur une violation de framing. On ne tente **pas** de frame de
    /// close « polie » : le pair est déjà hors contrat et la priorité est d'arrêter
    /// d'accumuler. `finish()` (déclenché par `stateUpdateHandler`) purgera les demandes
    /// encore en vol côté UI — aucune ne reste orpheline.
    private func failProtocol(_ reason: String) {
        IDELog.log("framing invalide, connexion coupée : \(reason)")
        inbound.removeAll()
        fragment.removeAll()
        conn.cancel()
    }

    // MARK: - Écriture

    private func sendRaw(_ s: String, then done: (() -> Void)? = nil) {
        guard !closed else { return }
        conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in done?() })
    }

    private func sendFrame(opcode: UInt8, payload: Data, then done: (() -> Void)? = nil) {
        // Aucun `send` après fermeture : le socket est mort, et une écriture tardive
        // signalerait surtout un bug de cycle de vie. On le journalise pour le voir.
        guard !closed else {
            IDELog.log("écriture ignorée : connexion déjà fermée (opcode \(opcode))")
            return
        }
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
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            // `clientInfo` = { name, version } : la seule occasion d'apprendre à quelle
            // version de `claude` on parle **sans lancer de process**. T8 la compare à
            // `IDEProtocolContract.lastValidatedClaudeVersion` pour l'empreinte de
            // version (signal informatif ; le signal faisant autorité reste la
            // vérification du disque après acceptation).
            let info = params["clientInfo"] as? [String: Any]
            onClientHello?(info?["name"] as? String, info?["version"] as? String)
            // On écho la version protocole du client (plus sûr que la figer).
            let client = params["protocolVersion"] as? String
            reply(id: id, result: [
                "protocolVersion": client ?? "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "potof-toolkit-ide", "version": "1.0"],
            ])
        case "ide_connected":
            // Notification (sans id, rien à répondre) mais **la plus précieuse** : elle
            // porte le pid du `claude` distant, seule donnée d'identité que le protocole
            // livre. `IDEClientIdentity` en déduit le cwd (lsof) → worktree → branche,
            // sans quoi 4–5 agents parallèles produisent des demandes indiscernables.
            if let pid = Self.pid(from: params) { onClientPID?(pid) }
        case "notifications/initialized", "initialized":
            break // notifications (sans id) : rien à répondre
        case "tools/list":
            reply(id: id, result: ["tools": IDEProtocolContract.toolDefs])
        case "tools/call":
            handleToolCall(id: id, params: params)
        default:
            if id != nil { reply(id: id, result: [:]) }
        }
    }

    /// Extrait le pid d'une notification `ide_connected`. Tolérant sur le type :
    /// `JSONSerialization` rend un `NSNumber` pour un entier JSON, mais rien n'oblige
    /// le CLI à ne jamais passer une chaîne — et un pid manqué coûte l'identification
    /// de l'agent pour toute la durée de la connexion.
    private static func pid(from params: [String: Any]) -> Int32? {
        if let n = params["pid"] as? NSNumber { return Int32(exactly: n.int64Value) }
        if let s = params["pid"] as? String { return Int32(s) }
        return nil
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case IDEProtocolContract.ToolName.openDiff:
            // L'`id` de l'`IDEDiffRequest` (UUID) est **local** : le CLI ne fournit
            // aucune identité de demande, et son `id` JSON-RPC ne descend pas jusqu'à
            // l'UI. C'est cet UUID qui appariera le verdict à l'appel bloquant précis
            // qui l'attend — indispensable dès qu'il y a plus d'un `openDiff` en vol.
            let req = IDEDiffRequest(
                id: UUID(),
                oldPath: args["old_file_path"] as? String ?? "",
                newPath: args["new_file_path"] as? String ?? "",
                newContents: args["new_file_contents"] as? String ?? "",
                tabName: args["tab_name"] as? String ?? "")
            inFlight[req.id] = InFlightDiff(rpcID: id, tabName: req.tabName, receivedAt: Date())
            IDELog.log("openDiff \(Self.short(req.id)) reçu : \(req.tabName) "
                       + "— \(inFlight.count) en vol sur cette connexion")
            // Bloquant : on ne répond qu'une fois le verdict connu. La complétion peut
            // arriver de n'importe quel thread (clic dans l'UI, purge du centre de
            // revue) → on la re-sérialise sur la file de la connexion, seule autorisée
            // à toucher `inFlight` et à écrire des frames.
            handlers.openDiff(req) { [weak self] verdict in
                guard let self else { return }
                self.queue.async { self.completeDiff(req.id, verdict) }
            }
        case IDEProtocolContract.ToolName.getWorkspaceFolders:
            replyToolText(id: id, text: Self.jsonString([
                "folders": [["name": workspace.lastPathComponent,
                             "uri": "file://\(workspace.path)",
                             "path": workspace.path]],
                "rootPath": workspace.path,
            ]))
        case IDEProtocolContract.ToolName.getOpenEditors:
            replyToolText(id: id, text: #"{"tabs":[]}"#)
        case IDEProtocolContract.ToolName.getCurrentSelection,
             IDEProtocolContract.ToolName.getLatestSelection:
            replyToolText(id: id, text: #"{"success":false,"message":"no selection"}"#)
        case IDEProtocolContract.ToolName.getDiagnostics:
            replyToolText(id: id, text: "[]")
        case IDEProtocolContract.ToolName.closeTab:
            let tab = args["tab_name"] as? String ?? ""
            // D'abord libérer les appels bloquants portant ce `tab_name` : `close_tab`
            // signifie que le CLI a abandonné l'aperçu (Ctrl-C, sous-agent interrompu),
            // mais l'`openDiff` correspondant, lui, **attend toujours** une réponse.
            rejectInFlight(where: { $0.tabName == tab }, reason: "close_tab « \(tab) »")
            // Puis faire retirer l'aperçu côté UI. Les deux gestes sont idempotents :
            // le refus que le centre de revue va émettre retombera sur la garde de
            // `completeDiff` (la demande n'est déjà plus dans `inFlight`).
            handlers.closeTab(tab)
            replyToolContent(id: id, content: IDEProtocolContract.closedTabContent())
        case IDEProtocolContract.ToolName.closeAllDiffTabs:
            let n = rejectInFlight(where: { _ in true }, reason: "closeAllDiffTabs")
            handlers.closeAllTabs()
            // `n` = le nombre réel d'aperçus qu'on avait en vol. L'ancien `0` en dur
            // masquait toute anomalie de comptage côté CLI comme côté log.
            replyToolContent(id: id, content: IDEProtocolContract.closedAllTabsContent(count: n))
        default:
            replyToolText(id: id, text: "OK")
        }
    }

    // MARK: - Résolution des demandes en vol

    /// Répond à **une** demande `openDiff`. À n'appeler que depuis `queue`.
    ///
    /// **Idempotence.** La même demande peut légitimement être « résolue » deux fois :
    /// l'utilisateur clique Accepter à l'instant où un `close_tab` arrive, ou la purge
    /// de fermeture fait refuser une demande dont le verdict était déjà en route. Le
    /// retrait du dictionnaire **est** la garde — la seconde tentative ne trouve rien et
    /// n'émet **aucune** frame. Deux réponses au même `id` JSON-RPC seraient au mieux
    /// ignorées avec une erreur côté CLI, au pire appliquées deux fois.
    private func completeDiff(_ requestID: UUID, _ verdict: IDEDiffVerdict) {
        guard let entry = inFlight.removeValue(forKey: requestID) else {
            IDELog.log("verdict \(verdict.logLabel) ignoré : demande \(Self.short(requestID)) "
                       + "déjà résolue (close_tab, purge, ou double clic)")
            return
        }
        let waited = String(format: "%.1f", Date().timeIntervalSince(entry.receivedAt))
        IDELog.log("openDiff \(Self.short(requestID)) → \(verdict.logLabel) après \(waited) s "
                   + "— \(inFlight.count) encore en vol")
        // ⚠️ Passe **obligatoirement** par le contrat : une acceptation vaut DEUX blocs
        // de contenu (défaut D1 — cf. `IDEProtocolContract.acceptedContent`). Un seul
        // bloc et le CLI part en `TypeError` → « Failed to show diff in IDE ».
        replyToolContent(id: entry.rpcID, content: IDEProtocolContract.content(for: verdict))
    }

    /// Résout en `.rejected` toutes les demandes en vol vérifiant `predicate`, en
    /// **répondant sur le socket** (la connexion est vivante : ces appels bloquants
    /// doivent être libérés, sans quoi l'agent attend une réponse qui ne viendra pas).
    ///
    /// Retire **avant** d'émettre, pour la même raison que `finish()` : le refus peut
    /// réentrer par l'UI et doit tomber sur la garde d'idempotence.
    /// Renvoie le nombre de demandes libérées — c'est le `n` de `CLOSED_<n>_DIFF_TABS`.
    @discardableResult
    private func rejectInFlight(where predicate: (InFlightDiff) -> Bool, reason: String) -> Int {
        let doomed = inFlight.filter { predicate($0.value) }
        guard !doomed.isEmpty else { return 0 }
        for key in doomed.keys { inFlight.removeValue(forKey: key) }
        IDELog.log("\(doomed.count) demande(s) libérée(s) en DIFF_REJECTED — \(reason)")
        for entry in doomed.values {
            replyToolContent(id: entry.rpcID, content: IDEProtocolContract.content(for: .rejected))
        }
        return doomed.count
    }

    // MARK: - Fabriques de réponses

    private func reply(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        sendText(str)
    }

    private func replyToolText(id: Any?, text: String) {
        replyToolContent(id: id, content: IDEProtocolContract.textContent(text))
    }

    /// Réponse d'outil MCP avec un tableau `content` **déjà construit** : seul moyen
    /// d'émettre les réponses multi-blocs qu'exige l'acceptation d'un `openDiff`.
    private func replyToolContent(id: Any?, content: [[String: Any]]) {
        reply(id: id, result: ["content": content])
    }

    /// 8 premiers caractères de l'UUID : assez pour suivre une demande dans `ide.log`
    /// sans le noyer, alors qu'il y en a plusieurs en parallèle.
    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private static func jsonString(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
