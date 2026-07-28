import Foundation
import Network
import CryptoKit
import SwiftTerm

/// **Auto-test du contrat protocolaire `claude` ↔ IDE** (T10 du plan `PLAN_IDE_HOST.md`).
///
/// Raison d'être : le protocole d'intégration IDE de Claude Code n'est **pas officiel** et
/// **a déjà cassé en silence**. Entre `claude 2.1.205` et `2.1.220`, l'acceptation d'un
/// `openDiff` est passée d'**un** bloc de contenu à **deux** (`IDEProtocolContract.acceptedContent`) :
/// pendant des mois l'app a cru accepter alors que le CLI levait un `TypeError`, retombait
/// sur son prompt de permission terminal, et n'appliquait jamais l'édition. Aucun test
/// unitaire ne pouvait voir ça — seul un aller-retour avec le **vrai binaire installé** le
/// révèle. D'où ce mode : une commande, un compte rendu par point du contrat §2 du plan.
///
/// Deux modes, tous deux **hors GUI** (ils vivent avant/à côté de `NSApplication`, cf.
/// `main.swift`) et tous deux sur un hôte **isolé** (port éphémère + lock dédié) : ils ne
/// touchent jamais à `IDEHost.shared`, ni aux réglages, ni au lock de l'app installée.
///
/// - `--ide-selftest <dossier> [accept]` : monte le **serveur de production** (`IDEServer`)
///   sur ce dossier, imprime `PORT=<n>` et attend. Pour brancher un `claude` lancé à la
///   main et observer `ide.log`. Comportement historique, conservé tel quel.
/// - `--ide-selftest --e2e` : **entièrement automatique**. Dossier jetable, hôte isolé,
///   vrai `claude` dans un vrai PTY, consigne d'édition déterministe, acceptation
///   automatique, puis assertions — dont la seule qui fasse autorité : **le contenu du
///   fichier sur disque**.
enum IDESelfTest {

    /// Point d'entrée du drapeau. **Ne revient jamais** : soit le mode manuel part en
    /// `dispatchMain()`, soit l'e2e finit par `exit(...)`. C'est ce qui garantit que le
    /// mode diagnostic ne démarre **jamais** l'UI ni l'hôte IDE global de l'app.
    static func run(arguments: [String], flagIndex: Int) -> Never {
        if arguments.contains("--e2e") {
            E2ESelfTest(arguments: arguments).run()
        }
        runManual(arguments: arguments, flagIndex: flagIndex)
    }

    // MARK: - Mode manuel (inchangé)

    /// Monte l'`IDEServer` **de production** sur un dossier et attend. Le port éphémère
    /// est imprimé sur stdout (`PORT=<n>`) et le lock écrit dans `~/.claude/ide` : un
    /// `claude` lancé à la main avec `CLAUDE_CODE_SSE_PORT=<n>` s'y connecte à coup sûr
    /// (l'env court-circuite le scan des locks, cf. `IDEProtocolContract`).
    ///
    /// Sans argument `accept`, `onOpenDiff` reste nil ⇒ **refus systématique** : on valide
    /// le tuyau sans jamais écrire de fichier.
    private static func runManual(arguments: [String], flagIndex: Int) -> Never {
        let next = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : nil
        // Un drapeau (`--e2e`, …) n'est pas un dossier : ne pas le confondre avec le
        // chemin optionnel, sinon on monterait l'hôte sur un dossier « --e2e ».
        let folder = (next.map { $0.hasPrefix("-") } ?? true)
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            : URL(fileURLWithPath: next!)

        let server = IDEServer(sessionID: UUID(), workspace: folder)
        guard let port = server.port else {
            FileHandle.standardError.write(Data("ide-selftest: réservation de port échouée\n".utf8))
            exit(1)
        }
        if arguments.contains("accept") {
            // Accepte **le contenu proposé tel quel** : c'est ce contenu que le CLI
            // reprendra comme input de l'outil `Edit`/`Write` (cf. IDEProtocolContract).
            server.onOpenDiff = { req, done in done(.saved(content: req.newContents)) }
        }
        server.start()

        // Ctrl-C / `kill` doivent **supprimer le lock**. Sans ça, un
        // `~/.claude/ide/<port>.lock` survit au process : `claude` ne purge que les locks
        // dont le pid est mort, et un pid recyclé passerait au travers — pendant ce temps,
        // deux IDE « valides » suffisent à neutraliser l'auto-connexion (§2.1).
        // `SIG_IGN` puis `DispatchSourceSignal` : un handler C ne pourrait pas appeler ça.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { server.stop(); exit(0) }
            src.resume()
            manualSignalSources.append(src)
        }

        print("PORT=\(port)")
        fflush(stdout)
        dispatchMain()
    }

    /// Sources de signaux du mode manuel : à retenir en vie tant que le process tourne
    /// (une `DispatchSourceSignal` relâchée cesse de délivrer).
    private static var manualSignalSources: [DispatchSourceSignal] = []
}

// MARK: - Points de contrat

/// Un point du **contrat §2 du plan**, avec son verdict. L'ordre de `allCases` est celui
/// du compte rendu : il suit la chronologie réelle d'une session (découverte → handshake
/// → session MCP → outil → disque), pour qu'un `FAIL` se lise comme « ça s'est arrêté là ».
private enum ContractPoint: Int, CaseIterable {
    case handshake, auth, initialize, toolsList, openDiff, fileSaved, disk, noPrompt

    var title: String {
        switch self {
        case .handshake:  return "handshake WebSocket"
        case .auth:       return "en-tête d'auth validé"
        case .initialize: return "initialize (version de claude observée)"
        case .toolsList:  return "tools/list"
        case .openDiff:   return "openDiff reçu"
        case .fileSaved:  return "réponse FILE_SAVED à deux blocs acceptée"
        case .disk:       return "fichier modifié sur disque"
        case .noPrompt:   return "aucun prompt de permission dans le terminal"
        }
    }

    /// Section du plan / du contrat à rouvrir quand ce point tombe.
    var reference: String {
        switch self {
        case .handshake, .auth:            return "§2.1"
        case .initialize, .toolsList,
             .openDiff, .fileSaved, .disk: return "§2.3"
        case .noPrompt:                    return "§2.4"
        }
    }

    /// **Pourquoi** cette assertion existe — ce qu'un `FAIL` signifierait concrètement.
    /// Imprimé sous le point quand il ne passe pas : c'est le diagnostic de première
    /// intention pour qui relance le test après une montée de version de `claude`.
    var why: String {
        switch self {
        case .handshake:
            return "sans upgrade 101 + sous-protocole `mcp` échoé, `claude` referme la "
                 + "connexion juste après l'upgrade : plus aucun diff n'arrive dans l'app."
        case .auth:
            return "le lock publie `authToken`, que le CLI renvoie dans "
                 + "`X-Claude-Code-Ide-Authorization`. Au-delà du binding 127.0.0.1 c'est "
                 + "la SEULE barrière (périmètre $HOME = tout process local peut frapper)."
        case .initialize:
            return "ouverture de la session MCP. `clientInfo.version` est la seule façon "
                 + "d'apprendre à quelle version de `claude` on parle sans lancer de "
                 + "process — c'est l'empreinte de version d'`IDEContractGuard`."
        case .toolsList:
            return "`openDiff` doit être déclaré avec ses 4 champs requis. Un outil annoncé "
                 + "mais non servi (ou l'inverse) produit un `tools/call` sans réponse : "
                 + "l'appel est BLOQUANT, l'agent se fige sans message d'erreur."
        case .openDiff:
            return "preuve que l'édition passe bien par l'IDE (éligibilité `eSd` : Edit/Write, "
                 + "hors .ipynb, `diffTool: auto`) et non par le prompt du terminal."
        case .fileSaved:
            return "défaut D1 du plan : `content[0]=\"FILE_SAVED\"` + `content[1]=<contenu>`. "
                 + "Avec UN seul bloc, `content[1]` est `undefined` côté CLI → TypeError → "
                 + "« Failed to show diff in IDE » et l'édition n'est jamais appliquée."
        case .disk:
            return "le 2ᵉ bloc devient l'input réel de l'outil. C'est le seul signal FAISANT "
                 + "AUTORITÉ, indépendant de la version du CLI : si le disque n'a pas bougé, "
                 + "le contrat est rompu quoi que dise le reste."
        case .noPrompt:
            return "le panneau de diff EST le prompt de permission. Un prompt resté affiché "
                 + "dans le terminal est le symptôme EXACT de la régression 2.1.205→2.1.220 : "
                 + "le CLI n'a pas compris notre réponse et est retombé sur son propre prompt."
        }
    }
}

/// Verdict d'un point. `skip` = **non évalué** (la séquence s'est arrêtée avant) : traité
/// comme un échec pour le code de sortie — un point qu'on n'a pas pu prouver n'est pas un
/// point qui passe.
private enum PointStatus: String {
    case pass = "PASS", fail = "FAIL", skip = "SKIP"
}

/// Compte rendu ordonné. Mutations **sur le thread principal** uniquement.
private final class ContractReport {
    private var status: [ContractPoint: PointStatus] = [:]
    private var detail: [ContractPoint: String] = [:]

    func set(_ point: ContractPoint, _ s: PointStatus, _ d: String) {
        status[point] = s
        detail[point] = d
    }

    /// N'écrit que si le point est encore vierge — utilisé pour les constats tardifs qui
    /// ne doivent pas écraser un verdict déjà posé (ex. la purge finale en `SKIP`).
    func setIfUnset(_ point: ContractPoint, _ s: PointStatus, _ d: String) {
        guard status[point] == nil else { return }
        set(point, s, d)
    }

    var allPassed: Bool { ContractPoint.allCases.allSatisfy { status[$0] == .pass } }
    var passCount: Int { ContractPoint.allCases.filter { status[$0] == .pass }.count }

    /// Rend le tableau final. Le `why` n'est imprimé que sous les points en échec : sur un
    /// run vert on veut huit lignes lisibles, pas trois pages.
    func render() -> String {
        var out = ""
        let width = ContractPoint.allCases.map { $0.title.count }.max() ?? 0
        for p in ContractPoint.allCases {
            let s = status[p] ?? .skip
            let padded = p.title.padding(toLength: width, withPad: " ", startingAt: 0)
            out += "[\(s.rawValue)] \(padded)  \(p.reference)  \(detail[p] ?? "non évalué")\n"
            if s != .pass {
                out += "        ↳ pourquoi : \(p.why)\n"
            }
        }
        return out
    }
}

// MARK: - Hôte IDE isolé, instrumenté

/// Hôte IDE **du banc de test** : un `NWListener` sur `127.0.0.1:<port éphémère>`, un lock
/// `~/.claude/ide/<port>.lock`, et de vraies `IDEConnection` — c'est-à-dire **le code de
/// production qui porte tout le contrat** (handshake, validation du token, framing RFC 6455,
/// JSON-RPC/MCP, fabriques de réponse via `IDEProtocolContract`).
///
/// Pourquoi ne pas réutiliser `IDEServer` ici : `IDEServer` n'expose que `onConnected` et
/// `onOpenDiff`, alors que le compte rendu doit **observer** `initialize` (pour lire la
/// version annoncée par le CLI) — un seam que `IDEConnection` publie (`onClientHello`) mais
/// que ses deux emballages de production ne relaient pas jusqu'ici. Ce qui est dupliqué se
/// limite donc à l'enveloppe transport (listener + lock, les mêmes ~40 lignes qu'ont déjà
/// `IDEServer` ET `IDEHost`) ; le contrat, lui, n'est pas ré-implémenté une seule ligne.
///
/// **Thread** : l'état vit sur `netQueue` (série). Les seams sont **remarshalés sur `main`**,
/// où vit toute la machine à états du test.
private final class SelfTestHost {

    /// Dossier annoncé à l'agent par `getWorkspaceFolders` (= le dossier jetable du test).
    let workspace: URL
    /// Token publié dans le lock et exigé au handshake. Jamais imprimé dans le compte rendu.
    let token: String
    private(set) var port: UInt16?

    /// Index de client (ordre d'arrivée), pour distinguer la sonde interne du vrai `claude`.
    private var nextClient = 0
    private var connections: [Int: IDEConnection] = [:]
    private var listener: NWListener?
    private let netQueue = DispatchQueue(label: "com.potof.toolkit.ide.selftest.host")

    var onHandshake: ((Int) -> Void)?
    var onClientHello: ((Int, String?, String?) -> Void)?
    var onOpenDiff: ((Int, IDEDiffRequest, @escaping (IDEDiffVerdict) -> Void) -> Void)?
    var onCloseTab: ((Int, String?) -> Void)?

    init(workspace: URL) {
        self.workspace = workspace
        // Même forme que la production : 256 bits d'aléa opaque issus du CSPRNG système.
        var out = ""
        out.reserveCapacity(64)
        for _ in 0..<32 { out += String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }
        self.token = out
    }

    /// Instant à partir duquel les handshakes sont servis (banc d'essai ; `nil` =
    /// tout de suite). Écrit depuis `main` avant le spawn, lu depuis `netQueue` :
    /// une `Date?` est une valeur, et la seule conséquence d'une lecture décalée serait
    /// de servir un instant trop tôt — sans effet sur la conclusion.
    private var acceptFrom: Date?

    /// Rétention **événementielle** du handshake : tant que c'est vrai, les connexions sont
    /// acceptées au niveau TCP mais laissées en attente. `releaseHandshakes()` les libère.
    /// Sert à rendre la course « premier tour vs connexion IDE » indépendante du temps de
    /// réflexion du modèle, qui varie de 5 à 30 s et ruine tout réglage par minuterie.
    private var handshakesHeld = false
    private var heldConnections: [IDEConnection] = []

    /// Diffère le handshake d'une durée fixe (voir `POTOF_SELFTEST_ACCEPT_DELAY`).
    func deferAccept(for seconds: TimeInterval) {
        guard seconds > 0 else { return }
        acceptFrom = Date().addingTimeInterval(seconds)
    }

    /// Retient les handshakes jusqu'à `releaseHandshakes()` (voir
    /// `POTOF_SELFTEST_ACCEPT_AFTER_TOOL`).
    func holdHandshakes() {
        netQueue.sync { handshakesHeld = true }
    }

    /// Libère les handshakes retenus, et tous ceux à venir. Idempotent.
    func releaseHandshakes() {
        netQueue.async {
            guard self.handshakesHeld else { return }
            self.handshakesHeld = false
            let waiting = self.heldConnections
            self.heldConnections.removeAll()
            IDELog.log("selftest: handshakes libérés (\(waiting.count) connexion(s) en attente)")
            for c in waiting { c.start(queue: self.netQueue) }
        }
    }

    /// Nombre de clients déjà acceptés. Lu **synchroniquement** juste avant de lancer
    /// `claude` : tout index strictement inférieur appartient à la sonde interne, et ses
    /// événements (qui arrivent sur `main`, donc *après* le démarrage de `dispatchMain`)
    /// ne doivent surtout pas être attribués au CLI.
    func clientCountSnapshot() -> Int { netQueue.sync { nextClient } }

    var lockURL: URL? {
        port.map {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/ide/\($0).lock")
        }
    }

    /// Démarre le listener et publie le lock. **Synchrone** (attend l'état `.ready`) :
    /// tout le montage du test se fait avant `dispatchMain()`, où le thread principal est
    /// encore libre de bloquer.
    func start(timeout: TimeInterval = 5) -> String? {
        guard let reserved = Self.reserveEphemeralPort() else {
            return "aucun port éphémère disponible"
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback SEULEMENT : le banc de test n'ouvre rien sur le réseau.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                 port: NWEndpoint.Port(rawValue: reserved)!)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { return "listener: \(error)" }

        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = "listener en échec: \(e)"; ready.signal()
            case .cancelled: failure = failure ?? "listener annulé"; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] nwc in self?.accept(nwc) }
        l.start(queue: netQueue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            l.cancel()
            return "listener non prêt après \(Int(timeout)) s"
        }
        if let failure { l.cancel(); return failure }

        listener = l
        port = reserved
        writeLock()
        IDELog.log("selftest: hôte isolé prêt sur 127.0.0.1:\(reserved) — workspace \(workspace.path)")
        return nil
    }

    /// Coupe tout et **supprime le lock**. Idempotent : appelé par le chemin nominal comme
    /// par la purge d'échec — un lock laissé derrière ferait échouer la découverte des
    /// `claude` suivants (le CLI ne purge que les locks dont le pid est mort, et notre pid,
    /// lui, est bien vivant… jusqu'à l'`exit`).
    func stop() {
        if let url = lockURL { try? FileManager.default.removeItem(at: url) }
        listener?.cancel()
        listener = nil
        netQueue.sync {
            for (_, c) in connections { c.cancel() }
            connections.removeAll()
        }
        port = nil
    }

    /// Accepte une connexion **sur `netQueue`** (et non sur `main` comme le fait `IDEHost`,
    /// qui doit y toucher son état `@Published`) : la sonde interne tourne avant
    /// `dispatchMain()`, donc un remarshalage sur `main` la ferait attendre indéfiniment.
    private func accept(_ nwc: NWConnection) {
        let index = nextClient
        nextClient += 1
        let handlers = IDEDiffHandlers(
            openDiff: { [weak self] req, done in
                DispatchQueue.main.async {
                    guard let self, let h = self.onOpenDiff else { done(.rejected); return }
                    h(index, req, done)
                }
            },
            closeTab: { [weak self] tab in
                DispatchQueue.main.async { self?.onCloseTab?(index, tab) }
            },
            closeAllTabs: { [weak self] in
                DispatchQueue.main.async { self?.onCloseTab?(index, nil) }
            })
        let conn = IDEConnection(nwc: nwc, token: token, workspace: workspace, handlers: handlers)
        conn.onHandshake = { [weak self] in
            DispatchQueue.main.async { self?.onHandshake?(index) }
        }
        conn.onClientHello = { [weak self] name, version in
            DispatchQueue.main.async { self?.onClientHello?(index, name, version) }
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            self.netQueue.async { self.connections[index] = nil }
        }
        connections[index] = conn

        // Bancs d'essai : on accepte la connexion TCP mais on **retarde notre 101**. Le CLI
        // patiente (son `initialize` a 30 s de budget) et finit par se connecter, simplement
        // plus tard. C'est ce qui rend déterministe la course « premier tour vs client ide » ;
        // sans levier, l'IDE est connecté en ~40 ms et gagne presque toujours.
        // (Refuser la connexion, à l'inverse, ne marche pas : le CLI ne réessaie jamais.)
        if handshakesHeld {
            IDELog.log("selftest: handshake du client \(index) retenu (banc d'essai événementiel)")
            heldConnections.append(conn)
            return
        }
        if let until = acceptFrom, Date() < until {
            let wait = until.timeIntervalSinceNow
            IDELog.log("selftest: handshake du client \(index) retardé de "
                       + String(format: "%.1f", wait) + " s (banc d'essai)")
            netQueue.asyncAfter(deadline: .now() + wait) { [weak conn] in
                conn?.start(queue: self.netQueue)
            }
            return
        }
        conn.start(queue: netQueue)
    }

    /// Forme **exacte** attendue par le CLI (vérifiée en 2.1.220) : le port est le nom du
    /// fichier, le contenu porte le périmètre et le token.
    private func writeLock() {
        guard port != nil, let url = lockURL else { return }
        let lock: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": [workspace.path],
            "ideName": IDEProtocolContract.ideName + " (selftest)",
            "transport": "ws",
            "runningInWindows": false,
            "authToken": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: lock) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// Bind `127.0.0.1:0` → lecture du port attribué → close. Même geste que la production.
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
}

// MARK: - Sonde MCP synchrone

/// Client MCP **minimal** (sockets POSIX bloquants + framing WebSocket côté client) qui
/// interroge notre propre hôte avant de lancer `claude`.
///
/// Il couvre deux points que le CLI, lui, ne permet pas d'observer depuis l'app :
/// - **l'auth des deux côtés** : un token bidon doit produire un `401` (le chemin nominal,
///   lui, est prouvé par le vrai `claude` qui se connecte ensuite avec le token du lock) ;
/// - **`tools/list`** : `IDEConnection` y répond sans passer par le moindre seam, donc la
///   seule manière de vérifier la déclaration d'`openDiff` et de ses quatre champs requis,
///   c'est de la demander nous-mêmes.
///
/// Volontairement écrit **à la main** : côté client il faut masquer les frames (RFC 6455
/// §5.3), ce que `NWProtocolWebSocket` ferait — mais au prix d'un client asynchrone dans un
/// programme dont le thread principal, à cet instant, n'a pas encore de boucle d'événements.
private final class MiniMCPClient {

    private var fd: Int32 = -1
    private var inbound = Data()

    init?(port: UInt16, timeoutSeconds: Int = 5) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(s); return nil }
        fd = s
    }

    deinit { disconnect() }

    func disconnect() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    // MARK: E/S brutes

    @discardableResult
    private func writeAll(_ data: Data) -> Bool {
        guard fd >= 0, !data.isEmpty else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Un tour de `recv`. `false` = EOF, erreur ou dépassement du `SO_RCVTIMEO`.
    private func fill() -> Bool {
        guard fd >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 16 << 10)
        let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return false }
        inbound.append(contentsOf: buf[0..<n])
        return true
    }

    // MARK: Handshake

    /// Envoie l'upgrade HTTP avec le token fourni et rend `(statut, en-têtes)`.
    /// `token == nil` ⇒ en-tête d'auth **omis** (l'autre polarité du contrôle).
    func handshake(port: UInt16, token: String?, subprotocol: String) -> (status: Int, headers: [String: String])? {
        var key = Data(count: 16)
        for i in 0..<16 { key[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        let keyB64 = key.base64EncodedString()

        var req = "GET / HTTP/1.1\r\n"
        req += "Host: 127.0.0.1:\(port)\r\n"
        req += "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: \(keyB64)\r\n"
        req += "Sec-WebSocket-Version: 13\r\n"
        req += "Sec-WebSocket-Protocol: \(subprotocol)\r\n"
        if let token {
            // Casse exacte du CLI (vérifiée) ; le serveur normalise en minuscules.
            req += "X-Claude-Code-Ide-Authorization: \(token)\r\n"
        }
        req += "\r\n"
        guard writeAll(Data(req.utf8)) else { return nil }

        while inbound.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard fill() else { return nil }
        }
        guard let sep = inbound.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = inbound.subdata(in: inbound.startIndex..<sep.lowerBound)
        inbound.removeSubrange(inbound.startIndex..<sep.upperBound)
        guard let raw = String(data: head, encoding: .utf8) else { return nil }

        let lines = raw.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { line -> Int? in
            let parts = line.split(separator: " ")
            return parts.count >= 2 ? Int(parts[1]) : nil
        } ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] =
                String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        // Vérification de l'accept RFC 6455 : c'est la preuve que le serveur a bien
        // dérivé la clé (et pas renvoyé un 101 de complaisance).
        let expected = Data(Insecure.SHA1.hash(
            data: Data((keyB64 + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        headers["__accept_matches__"] = headers["sec-websocket-accept"] == expected ? "1" : "0"
        return (status, headers)
    }

    // MARK: Framing client → serveur (masqué) et serveur → client

    private func sendText(_ text: String) -> Bool {
        let payload = [UInt8](text.utf8)
        var frame = Data([0x81])                      // FIN + opcode texte
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(0x80 | n))             // bit MASK obligatoire côté client
        } else if n <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8(n >> 8 & 0xFF)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(n >> i & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        frame.append(contentsOf: mask)
        var masked = payload
        for i in masked.indices { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)
        return writeAll(frame)
    }

    /// Lit une frame complète (serveur → client, donc **non masquée**). `nil` = plus rien.
    private func readFrame() -> (opcode: UInt8, payload: Data)? {
        while true {
            let base = inbound.startIndex
            if inbound.count >= 2 {
                let b0 = inbound[base], b1 = inbound[base + 1]
                var len = Int(b1 & 0x7F)
                var off = 2
                var enough = true
                if len == 126 {
                    if inbound.count >= 4 {
                        len = Int(inbound[base + 2]) << 8 | Int(inbound[base + 3]); off = 4
                    } else { enough = false }
                } else if len == 127 {
                    if inbound.count >= 10 {
                        var wide = 0
                        for i in 2..<10 { wide = wide << 8 | Int(inbound[base + i]) }
                        len = wide; off = 10
                    } else { enough = false }
                }
                if enough, inbound.count >= off + len {
                    let start = base + off
                    let payload = Data(inbound[start..<start + len])
                    inbound.removeSubrange(base..<start + len)
                    return (b0 & 0x0F, payload)
                }
            }
            guard fill() else { return nil }
        }
    }

    /// Appel JSON-RPC : émet puis attend la réponse portant le même `id` (les frames de
    /// contrôle et les notifications intercalaires sont ignorées).
    func call(method: String, params: [String: Any], id: Int) -> [String: Any]? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8),
              sendText(text) else { return nil }
        for _ in 0..<32 {
            guard let frame = readFrame() else { return nil }
            guard frame.opcode == 0x1 || frame.opcode == 0x2 else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
            else { continue }
            if let rid = obj["id"] as? Int, rid == id { return obj }
        }
        return nil
    }

    /// Notification (sans `id`, pas de réponse attendue).
    @discardableResult
    func notify(method: String, params: [String: Any] = [:]) -> Bool {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { msg["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return false }
        return sendText(text)
    }
}

// MARK: - Test de bout en bout

/// Machine à états du mode `--e2e`. **Tout son état vit sur le thread principal** (le
/// programme tourne sous `dispatchMain()`), sauf les lectures du terminal, sérialisées sur
/// `ptyQueue` — la file sur laquelle SwiftTerm alimente l'émulateur.
private final class E2ESelfTest {

    // MARK: Données du scénario

    /// Jeton « avant » présent dans le fichier jetable, et jeton « après » que l'édition
    /// doit produire. Deux chaînes improbables : l'assertion disque ne peut pas passer par
    /// hasard, et un `grep` sur le poste retrouve immédiatement un résidu de test.
    private static let beforeToken = "POTOF_SELFTEST_BEFORE"
    private static let afterToken = "POTOF_SELFTEST_AFTER"
    private static let fileName = "selftest.txt"
    /// Maillons 2 et 3 de la chaîne `notes/` (cf. la création du dossier jetable) : noms
    /// fixes — pour pouvoir les viser avec `POTOF_SELFTEST_RELEASE_ON` — mais impossibles
    /// à déduire du maillon précédent.
    private static let chainLink2 = "zulu-7f3"
    private static let chainLink3 = "quebec-91c"

    /// Consigne d'édition : déterministe, un seul outil, pas d'ambiguïté sur le fichier.
    /// En anglais, langue des outils du CLI — c'est ce qui oriente le plus sûrement vers
    /// `Edit` (seul, avec `Write`, à être éligible à `openDiff`, cf. `eSd` §2.2).
    ///
    /// ⚠️ **Elle est TAPÉE dans la TUI, jamais passée en `argv`** — et ce n'est pas un
    /// détail de style. Vérifié empiriquement contre 2.1.220 : avec `claude "<consigne>"`,
    /// le tour démarre **avant** que le client MCP « ide » ne soit connecté, et
    /// l'éligibilité au diff IDE se teste sur `r.options.mcpClients` (`eSd` :
    /// `clients.some(c => c.type === "connected" && c.name === "ide")`) — la liste du tour
    /// en cours. Résultat : **aucun `openDiff`**, le CLI retombe sur son prompt de
    /// permission terminal, alors même que la WebSocket est bien établie. Attendre le
    /// handshake avant de parler est donc une condition du contrat, pas une précaution.
    private static var instruction: String {
        if let custom = ProcessInfo.processInfo.environment["POTOF_SELFTEST_INSTRUCTION"],
           !custom.isEmpty {
            return custom
        }
        return "Use the Edit tool exactly once on the file \(fileName) in the current directory: "
             + "replace the text \(beforeToken) with \(afterToken). "
             + "Do not use any other tool, do not create or delete any file, "
             + "and reply with one short sentence when it is done."
    }

    /// **Bancs d'essai du piège « prompt en argv »** (non documentés dans l'aide : ce sont
    /// des leviers d'enquête, pas des options d'usage courant).
    ///
    /// - `POTOF_SELFTEST_ARGV=1` : passe la consigne en `argv` au lieu de la taper, pour
    ///   **reproduire** la perte d'`openDiff` et en mesurer la portée exacte (une seule
    ///   édition très précoce ? tout le premier tour ? tout le run ?).
    /// - `POTOF_SELFTEST_INSTRUCTION=<texte>` : consigne de remplacement, pour forcer
    ///   plusieurs allers-retours d'outils avant la première édition.
    ///
    /// Le dossier jetable contient de quoi nourrir une consigne exploratoire :
    /// `notes/a.txt`, `notes/b.txt`, `notes/c.txt` (lisibles sans permission).
    private static var usesArgvPrompt: Bool {
        ProcessInfo.processInfo.environment["POTOF_SELFTEST_ARGV"] != nil
    }

    /// `POTOF_SELFTEST_ACCEPT_AFTER_TOOL=1` : retient le handshake IDE jusqu'à ce qu'un
    /// **appel d'outil ait effectivement eu lieu**. C'est le seul montage qui prouve, sans
    /// dépendre du temps de réflexion du modèle, qu'un tour a tourné SANS client « ide » —
    /// et donc qui départage « liste figée pour tout le run » de « liste rafraîchie entre
    /// les tours ».
    private static var holdsUntilFirstTool: Bool {
        ProcessInfo.processInfo.environment["POTOF_SELFTEST_ACCEPT_AFTER_TOOL"] != nil
            || releaseMarker != nil
    }

    /// `POTOF_SELFTEST_RELEASE_ON=<chaîne>` : libère le handshake dès que cette chaîne
    /// apparaît dans le terminal. Plus fiable que la détection d'un appel d'outil (la TUI
    /// ne rend pas tous les outils de la même façon) : en visant un marqueur que `claude`
    /// **ne peut connaître qu'après avoir lu un fichier** (le maillon suivant de la chaîne
    /// `notes/`), on obtient la preuve qu'un tour d'outils complet a eu lieu sans client « ide ».
    private static var releaseMarker: String? {
        ProcessInfo.processInfo.environment["POTOF_SELFTEST_RELEASE_ON"].flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    // MARK: État

    private let report = ContractReport()
    private let ptyQueue = DispatchQueue(label: "com.potof.toolkit.ide.selftest.pty")

    private var tmpDir: URL?
    private var targetFile: URL?
    private var host: SelfTestHost?
    private var terminal: HeadlessTerminal?
    /// pid **du process que ce test a lancé lui-même**, et le seul qu'il ait le droit de
    /// tuer. Le poste fait tourner d'autres `claude` (agents de l'utilisateur) : aucun
    /// `pkill`, aucune recherche par nom — on ne tue que ce pid et son groupe.
    private var claudePid: pid_t = 0
    private var claudePath = ""
    private var claudeVersion = "?"

    /// Index de client à partir duquel les événements de l'hôte viennent de `claude` et
    /// non de la sonde interne (cf. `SelfTestHost.clientCountSnapshot`).
    private var claudeClientFloor = 0
    private var sawClaudeHandshake = false
    /// Instant du handshake IDE : origine des temps pour l'envoi de la consigne.
    private var handshakeAt: Date?
    private var instructionSentAt: Date?
    private var announcedVersion: String?
    /// Réponses déjà envoyées au « Quick safety check ». **Plusieurs tentatives sont
    /// nécessaires** : `claude` ignore les frappes reçues dans les premières centaines de
    /// millisecondes après l'affichage d'un prompt (garde anti-type-ahead, vérifiée
    /// empiriquement — une seule Entrée envoyée dès la détection reste sans effet).
    private var trustAttempts = 0
    private var lastTrustSendAt: Date?
    private var pollTicks = 0
    private var releasedHandshakes = false
    /// `POTOF_SELFTEST_VERBOSE=1` → trace de scrutation dans le journal du pont.
    private static let verbose = ProcessInfo.processInfo.environment["POTOF_SELFTEST_VERBOSE"] != nil
    private var verdictSentAt: Date?
    private var acceptedContentLength = 0
    private var finished = false
    private var signalSources: [DispatchSourceSignal] = []
    /// `--keep` : conserve le dossier jetable (et son `ide.log`) pour l'autopsie. Le
    /// process et le lock, eux, sont **toujours** nettoyés.
    private let keepArtifacts: Bool

    private let startedAt = Date()
    /// Plafond global. Un test qui bloque est pire qu'un test qui échoue : il faut un
    /// verdict, toujours, et le nettoyage qui va avec.
    private let globalTimeout: TimeInterval
    /// Au-delà, `claude` n'a pas ouvert de connexion IDE : binaire muet, non authentifié,
    /// ou lock non découvert. On coupe court avec la copie d'écran en pièce jointe.
    private let handshakeDeadline: TimeInterval = 45
    /// Laps après le handshake avant de parler : la TUI finit de se dessiner et le client
    /// MCP « ide » finit de s'enregistrer côté CLI.
    private let connectSettle: TimeInterval = 1.5
    /// Au-delà, la TUI n'a jamais paru prête à recevoir un prompt (écran figé sur autre
    /// chose). On abandonne **sans rien taper** — même règle qu'`InitClaudeMdCoordinator`.
    private let readyDeadline: TimeInterval = 40
    /// Au-delà, la consigne est partie mais aucun `openDiff` n'est arrivé : soit le modèle
    /// a choisi un autre outil, soit l'édition est repartie dans le prompt terminal.
    /// **Dérivé** du plafond global : une consigne exploratoire (plusieurs tours d'outils
    /// avant l'édition) doit pouvoir respirer sans qu'on touche à deux réglages.
    private let editDeadline: TimeInterval
    /// Après le verdict, laps laissé au CLI pour appliquer l'outil et finir son tour.
    private let applyDeadline: TimeInterval = 25
    /// Laps de stabilisation avant la photo d'écran finale (point « aucun prompt »).
    private let settleAfterWrite: TimeInterval = 3

    init(arguments: [String]) {
        self.keepArtifacts = arguments.contains("--keep")
        let raw = ProcessInfo.processInfo.environment["POTOF_SELFTEST_TIMEOUT"]
        let timeout = raw.flatMap(TimeInterval.init) ?? 90
        self.globalTimeout = timeout
        self.editDeadline = max(45, timeout * 0.6)
    }

    // MARK: Déroulé

    /// Monte tout **synchroniquement** (le thread principal est encore libre de bloquer),
    /// lance `claude`, arme les échéances, puis passe la main à `dispatchMain()`.
    /// Ne revient jamais : la sortie se fait par `finish(...)` → `exit(...)`.
    func run() -> Never {
        // Journal du pont redirigé dans le dossier du test : on ne pollue pas — et on
        // n'écrase surtout pas — l'`ide.log` de l'app installée, qui peut tourner à côté.
        // `setenv` avant le premier accès à `IDELog.fileURL` (static let paresseux).
        let scratch = Self.scratchRoot()
        let dir = scratch.appendingPathComponent("potof-ide-selftest-\(UUID().uuidString.prefix(8))",
                                                 isDirectory: true)
        if ProcessInfo.processInfo.environment["POTOF_IDE_LOG_FILE"] == nil {
            setenv("POTOF_IDE_LOG_FILE", dir.appendingPathComponent("ide.log").path, 1)
        }

        printHeaderPrologue()

        // 1. Le binaire. Sans lui, rien n'est évaluable : on le dit franchement.
        guard let path = Self.locateClaude() else {
            fail(prologue: """
                `claude` est introuvable.
                Cherché : $POTOF_SELFTEST_CLAUDE, ~/.local/bin/claude, ~/.claude/local/claude,
                chaque entrée de $PATH, puis `command -v claude` dans un shell de login.
                Installe le CLI (ou exporte POTOF_SELFTEST_CLAUDE=/chemin/vers/claude) et relance.
                """)
        }
        claudePath = path
        claudeVersion = Self.claudeVersion(at: path) ?? "?"

        // 2. Dossier jetable + fichier au contenu connu.
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(Self.fileName)
            try "ligne 1\n\(Self.beforeToken)\nligne 3\n".write(to: file, atomically: true, encoding: .utf8)
            // Matière à explorer (Glob/Read, sans permission) pour les consignes qui doivent
            // enchaîner plusieurs tours d'outils AVANT la première édition.
            // Une **chaîne** : chaque note ne révèle la suivante qu'une fois lue. Le modèle ne
            // peut donc pas tout regrouper en un seul tour — c'est le seul moyen fiable de
            // garantir plusieurs allers-retours d'outils AVANT l'édition (une consigne du
            // genre « fais ces 5 étapes une par une » est ignorée : Opus réfléchit 30 s puis
            // édite directement).
            let notes = dir.appendingPathComponent("notes", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            // ⚠️ Maillons volontairement **non devinables** (pas `a` → `b` → `c`) : sinon le
            // modèle peut sauter directement au dernier fichier, et l'apparition de son nom à
            // l'écran ne prouverait plus qu'une lecture a eu lieu. C'est cette preuve qui fait
            // toute la valeur du montage `POTOF_SELFTEST_RELEASE_ON`.
            let chain = [
                ("a", "NEXT_FILE: notes/\(Self.chainLink2).txt"),
                (Self.chainLink2, "NEXT_FILE: notes/\(Self.chainLink3).txt"),
                (Self.chainLink3, "FINAL_STEP: use the Edit tool on \(Self.fileName) to replace "
                    + "the text \(Self.beforeToken) with \(Self.afterToken)."),
            ]
            for (name, body) in chain {
                try "\(body)\n".write(to: notes.appendingPathComponent("\(name).txt"),
                                      atomically: true, encoding: .utf8)
            }
            tmpDir = dir
            targetFile = file
        } catch {
            fail(prologue: "impossible de préparer le dossier de test \(dir.path) : \(error)")
        }

        // 3. Hôte isolé + lock.
        let h = SelfTestHost(workspace: dir)
        if let err = h.start() {
            host = h
            fail(prologue: "impossible de monter l'hôte IDE isolé : \(err)")
        }
        host = h
        wireHost(h)

        printHeader()

        // 4. Sonde interne : auth (les deux polarités) et `tools/list`, que le CLI ne
        //    permet pas d'observer depuis l'app.
        probeServer(port: h.port ?? 0, token: h.token)

        // 5. Le vrai `claude`, dans un vrai PTY.
        claudeClientFloor = h.clientCountSnapshot()
        // Bancs d'essai : armés APRÈS la sonde interne (elle, doit pouvoir se connecter).
        if let raw = ProcessInfo.processInfo.environment["POTOF_SELFTEST_ACCEPT_DELAY"],
           let delay = TimeInterval(raw), delay > 0 {
            h.deferAccept(for: delay)
            progress("BANC D'ESSAI — handshake retardé de \(Int(delay)) s après le spawn")
        }
        if Self.holdsUntilFirstTool {
            h.holdHandshakes()
            progress("BANC D'ESSAI — handshake retenu jusqu'au PREMIER appel d'outil de `claude`")
        }
        guard spawnClaude(in: dir, port: h.port ?? 0) else {
            finish(prologue: "le PTY n'a pas pu être ouvert (LocalProcess.shellPid == 0)")
        }

        installSignalTraps()
        DispatchQueue.main.asyncAfter(deadline: .now() + globalTimeout) { [weak self] in
            self?.finish(prologue: "délai global de \(Int(self?.globalTimeout ?? 0)) s dépassé")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.poll() }
        dispatchMain()
    }

    // MARK: Câblage de l'hôte

    private func wireHost(_ h: SelfTestHost) {
        // Valeur capturée, pas l'hôte : un closure stocké *dans* `h` qui retiendrait `h`
        // formerait un cycle de rétention.
        let endpoint = "127.0.0.1:\(h.port.map(String.init) ?? "?")"
        // Point 1 — le handshake est le premier signal que le CLI nous a trouvés ET que
        // notre 101 lui convient (sous-protocole `mcp` échoé compris).
        h.onHandshake = { [weak self] client in
            guard let self, client >= self.claudeClientFloor, !self.sawClaudeHandshake else { return }
            self.sawClaudeHandshake = true
            self.handshakeAt = Date()
            self.report.set(.handshake, .pass, "client réel `claude` accepté sur \(endpoint)")
            self.progress("handshake WebSocket — `claude` connecté")
        }
        // Point 3 — `clientInfo` de `initialize` : la version que le CLI annonce lui-même.
        h.onClientHello = { [weak self] client, name, version in
            guard let self, client >= self.claudeClientFloor else { return }
            self.announcedVersion = version
            let expected = IDEProtocolContract.lastValidatedClaudeVersion
            let drift = (version != nil && version != expected)
                ? "  ⚠️ contrat validé pour \(expected) → RE-VÉRIFIER §2 du plan"
                : ""
            self.report.set(.initialize, .pass,
                            "clientInfo = \(name ?? "?") \(version ?? "?")\(drift)")
            self.progress("initialize — clientInfo \(name ?? "?") \(version ?? "?")")
        }
        // Point 5 — l'`openDiff` : la preuve que l'édition est routée vers l'IDE.
        h.onOpenDiff = { [weak self] client, req, done in
            guard let self else { done(.rejected); return }
            guard client >= self.claudeClientFloor else { done(.rejected); return }
            self.handleOpenDiff(req, done: done)
        }
        h.onCloseTab = { _, tab in
            IDELog.log("selftest: close_tab \(tab ?? "(tous)") reçu")
        }
    }

    /// Réception d'un `openDiff` : on **accepte le contenu proposé tel quel**, ce qui
    /// exerce exactement le chemin de production `.saved(content:)` →
    /// `IDEProtocolContract.acceptedContent` → deux blocs.
    private func handleOpenDiff(_ req: IDEDiffRequest, done: @escaping (IDEDiffVerdict) -> Void) {
        guard verdictSentAt == nil else {
            // Un second aperçu (l'agent insiste, ou un sous-agent) : on refuse pour ne pas
            // brouiller l'assertion disque, mais on ne bloque personne.
            IDELog.log("selftest: openDiff supplémentaire refusé (verdict déjà rendu)")
            done(.rejected)
            return
        }
        let proposes = req.newContents.contains(Self.afterToken)
        report.set(.openDiff, .pass,
                   "\(URL(fileURLWithPath: req.newPath).lastPathComponent) — "
                   + "\(req.newContents.utf8.count) o proposés, jeton attendu "
                   + (proposes ? "présent" : "ABSENT (le modèle a proposé autre chose)"))
        acceptedContentLength = req.newContents.utf8.count
        verdictSentAt = Date()
        done(.saved(content: req.newContents))
        progress("openDiff reçu → verdict FILE_SAVED (2 blocs) renvoyé")
        IDELog.log("selftest: verdict FILE_SAVED (2 blocs) émis pour \(req.tabName)")
    }

    /// Trace de progression : un test de 30 à 60 s doit montrer qu'il avance. Sortie
    /// **vidée à chaque ligne** (stdout est bufferisé par blocs dès qu'il est redirigé).
    private func progress(_ text: String) {
        print("· \(text)")
        fflush(stdout)
    }

    // MARK: Sonde

    /// Points 2 et 4. Le chemin nominal de l'auth est prouvé plus tard par le vrai CLI ;
    /// ici on ajoute la **polarité négative** (token faux ⇒ 401), la seule qui prouve que
    /// la garde existe vraiment plutôt que d'être toujours vraie.
    private func probeServer(port: UInt16, token: String) {
        guard port != 0 else {
            report.set(.auth, .skip, "hôte non démarré")
            report.set(.toolsList, .skip, "hôte non démarré")
            return
        }

        // --- 2a. Token faux → doit être rejeté en 401 sans upgrade.
        var rejected = "non testé"
        var rejectedOK = false
        if let bad = MiniMCPClient(port: port) {
            if let r = bad.handshake(port: port, token: "mauvais-token", subprotocol: IDEProtocolContract.webSocketSubprotocol) {
                rejectedOK = r.status == 401
                rejected = "token bidon → HTTP \(r.status)"
            } else {
                rejected = "token bidon → connexion coupée sans réponse"
            }
            bad.disconnect()
        }

        // --- 2b/1'. Token du lock → 101 + `Sec-WebSocket-Accept` correct + sous-protocole échoé.
        guard let good = MiniMCPClient(port: port),
              let up = good.handshake(port: port, token: token,
                                      subprotocol: IDEProtocolContract.webSocketSubprotocol) else {
            report.set(.auth, .fail, "impossible d'ouvrir la sonde sur 127.0.0.1:\(port)")
            report.set(.toolsList, .skip, "sonde indisponible")
            return
        }
        let upgraded = up.status == 101
        let acceptOK = up.headers["__accept_matches__"] == "1"
        let echoed = up.headers["sec-websocket-protocol"] == IDEProtocolContract.webSocketSubprotocol
        if upgraded && acceptOK && echoed && rejectedOK {
            report.set(.auth, .pass,
                       "token du lock → 101 (Sec-WebSocket-Accept conforme, sous-protocole « "
                       + "\(IDEProtocolContract.webSocketSubprotocol) » échoé) ; \(rejected)")
        } else {
            report.set(.auth, .fail,
                       "101=\(upgraded) accept=\(acceptOK) sous-protocole=\(echoed) ; \(rejected)")
        }

        // --- 4. `initialize` puis `tools/list` : `openDiff` doit être déclaré avec ses
        //        quatre champs requis (`old_file_path`, `new_file_path`,
        //        `new_file_contents`, `tab_name`) — les noms exacts que le CLI enverra.
        guard upgraded else {
            report.set(.toolsList, .skip, "pas d'upgrade WebSocket")
            good.disconnect()
            return
        }
        let hello = good.call(method: "initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "potof-selftest-probe", "version": "1.0"],
        ], id: 1)
        good.notify(method: "notifications/initialized")
        guard let listed = good.call(method: "tools/list", params: [:], id: 2),
              let result = listed["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            report.set(.toolsList, .fail,
                       "aucune réponse exploitable à tools/list (initialize = "
                       + ((hello?["result"] != nil) ? "OK" : "KO") + ")")
            good.disconnect()
            return
        }
        let names = tools.compactMap { $0["name"] as? String }
        let openDiffDef = tools.first { ($0["name"] as? String) == IDEProtocolContract.ToolName.openDiff }
        let required = ((openDiffDef?["inputSchema"] as? [String: Any])?["required"] as? [String]) ?? []
        let expectedFields = ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]
        let fieldsOK = expectedFields.allSatisfy { required.contains($0) }
        if openDiffDef != nil && fieldsOK {
            report.set(.toolsList, .pass,
                       "\(tools.count) outils déclarés (\(names.joined(separator: ", "))) — "
                       + "openDiff complet")
        } else {
            report.set(.toolsList, .fail,
                       "openDiff \(openDiffDef == nil ? "absent" : "incomplet") ; "
                       + "champs requis = \(required)")
        }
        good.disconnect()
    }

    // MARK: PTY

    /// Lance `claude` dans un **vrai PTY** via `HeadlessTerminal` (le couple
    /// `LocalProcess` + `Terminal` de SwiftTerm, sans la moindre `NSView`).
    ///
    /// Le TTY n'est pas un détail de confort : sans lui, `claude` ne passe pas en mode
    /// interactif, n'émet aucun prompt de permission — donc **aucun `openDiff`** — et le
    /// test ne prouverait rien. Et c'est le même émulateur qu'en production, donc l'écran
    /// **rendu** qu'on inspecte pour le dernier point est exactement celui qu'on lirait
    /// dans une session embarquée.
    private func spawnClaude(in dir: URL, port: UInt16) -> Bool {
        let ht = HeadlessTerminal(
            queue: ptyQueue,
            // 120×40 : assez large pour que la TUI ne replie pas les libellés de prompt
            // qu'on cherche ensuite dans le buffer. Scrollback généreux : le dernier point
            // ne lit que l'écran visible, mais le diagnostic d'échec lit tout.
            options: TerminalOptions(cols: 120, rows: 40, termName: "xterm-256color", scrollback: 4000),
            onEnd: { [weak self] code in
                DispatchQueue.main.async { self?.claudeExited(code) }
            })
        terminal = ht

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // `getEnvironmentVariables` exclut volontairement PATH : sans lui `claude` ne
        // retrouverait ni `git`, ni `rg`, ni ses propres sous-process.
        if let path = ProcessInfo.processInfo.environment["PATH"] { env.append("PATH=\(path)") }
        // Court-circuite le scan des locks (`lock.port === CLAUDE_CODE_SSE_PORT`, §2.1) :
        // le routage vers NOTRE hôte est garanti, quels que soient les autres IDE déclarés
        // sur le poste (l'app elle-même, WebStorm, une autre instance de test…).
        env.append("CLAUDE_CODE_SSE_PORT=\(port)")
        // Surtout PAS de `POTOF_SESSION_ID` : ce serait la clé de mapping des notifications
        // et le hook `claude-notify.js` polluerait le canal de l'app avec ce test.

        // **Aucun argument** en nominal : la consigne sera tapée après le handshake IDE
        // (cf. la documentation d'`instruction` — un prompt en `argv` démarre le tour avant
        // que le client « ide » n'existe, et l'édition repart alors dans le prompt terminal).
        // `POTOF_SELFTEST_ARGV=1` rebascule volontairement dans ce piège, pour l'étudier.
        let args = Self.usesArgvPrompt ? [Self.instruction] : []
        if Self.usesArgvPrompt {
            progress("MODE ARGV (POTOF_SELFTEST_ARGV) — consigne passée en argument")
            instructionSentAt = Date()
        }
        ht.process.startProcess(executable: claudePath,
                                args: args,
                                environment: env,
                                currentDirectory: dir.path)
        claudePid = ht.process.shellPid
        IDELog.log("selftest: claude \(claudeVersion) lancé (pid \(claudePid)) dans \(dir.path)")
        return claudePid > 0
    }

    private func claudeExited(_ code: Int32?) {
        guard !finished else { return }
        // Une sortie avant l'écriture du fichier n'est jamais nominale : `claude` reste
        // interactif après avoir répondu. C'est le symptôme d'un binaire qui refuse de
        // démarrer (non authentifié, dossier refusé, crash).
        guard targetFileContainsAfterToken() == false else { return }
        finish(prologue: "`claude` s'est arrêté prématurément (code \(code.map(String.init) ?? "?"))"
                       + diagnosticHint())
    }

    // MARK: Boucle de scrutation

    private func poll() {
        guard !finished else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let screen = visibleScreen()
        pollTicks += 1

        // Trace de scrutation (`POTOF_SELFTEST_VERBOSE=1`) : quand le harnais reste sourd —
        // écran vide, prompt non reconnu parce que `claude` a changé sa formulation — c'est
        // la seule façon de voir CE QU'IL LIT plutôt que de deviner. Journalisée, pas
        // imprimée : le compte rendu doit rester lisible.
        if Self.verbose, pollTicks % 5 == 1 {
            // La **séquence d'outils** est relevée sur le buffer COMPLET (scrollback inclus) :
            // les premiers tours ont déjà défilé hors de l'écran visible, et c'est justement
            // eux qu'il faut pouvoir dater par rapport au handshake IDE.
            IDELog.log("selftest[poll \(pollTicks) t=\(String(format: "%.1f", elapsed))s] "
                       + "écran \(screen.utf8.count) o, trust=\(Self.trustPromptVisible(screen)) "
                       + "outils=\(Self.toolCalls(in: fullBuffer())) "
                       + "— \(screen.split(separator: "\n").suffix(6).joined(separator: " ⏎ "))")
        }

        // (a) Le « Quick safety check » de `claude` sur un dossier neuf. C'est un préalable
        //     du harnais, PAS un prompt de permission d'édition : on n'y répond que sur
        //     CETTE formulation (« trust this folder » + « No, exit »), donc jamais sur un
        //     prompt de permission d'édition. Entrée = option 1 « Yes, I trust this folder »,
        //     présélectionnée. On répète tant que le dialogue reste affiché : le CLI jette
        //     les frappes trop précoces, et une frappe envoyée quand le dialogue n'est plus
        //     là ne peut pas arriver puisqu'on re-teste l'écran à chaque tour.
        if Self.trustPromptVisible(screen), trustAttempts < 20,
           lastTrustSendAt.map({ Date().timeIntervalSince($0) > 0.8 }) ?? true {
            trustAttempts += 1
            lastTrustSendAt = Date()
            if trustAttempts == 1 { progress("« trust this folder » détecté → Entrée") }
            IDELog.log("selftest: « trust this folder » — Entrée (tentative \(trustAttempts))")
            send("\r")
        }

        // (a') Banc d'essai événementiel : dès qu'un appel d'outil est visible à l'écran,
        //      le premier tour a **prouvé** qu'il tournait sans client « ide ». On libère
        //      alors le handshake et on observe si l'édition, plus loin dans la chaîne,
        //      obtient malgré tout son `openDiff`.
        if Self.holdsUntilFirstTool, !releasedHandshakes {
            let buffer = fullBuffer()
            let reason: String?
            if let marker = Self.releaseMarker {
                reason = buffer.contains(marker) ? "marqueur « \(marker) » vu à l'écran" : nil
            } else {
                let tools = Self.toolCalls(in: buffer)
                reason = tools.isEmpty ? nil : "premier outil observé (\(tools.joined(separator: ", ")))"
            }
            if let reason {
                releasedHandshakes = true
                progress("\(reason) → libération du handshake IDE")
                host?.releaseHandshakes()
            }
        }

        // (b) Non authentifié / onboarding : inutile d'attendre 45 s pour le dire.
        //     (`finish` ne revient jamais — d'où l'absence de `return` ci-dessous.)
        if let hint = Self.blockingScreenHint(screen) {
            finish(prologue: hint + diagnosticHint())
        }

        // (c) Le CLI ne nous a jamais trouvés. (Neutralisé tant que le banc d'essai retient
        //     volontairement le handshake : ce serait s'alarmer de sa propre expérience.)
        if !sawClaudeHandshake, elapsed > handshakeDeadline,
           !(Self.holdsUntilFirstTool && !releasedHandshakes) {
            finish(prologue: "`claude` n'a ouvert aucune connexion IDE en \(Int(handshakeDeadline)) s"
                           + diagnosticHint())
        }

        // (c') La consigne d'édition, **après** le handshake et une fois la TUI au repos.
        //      L'ordre est structurant (cf. `instruction`) : parler avant que le client
        //      « ide » ne soit enregistré côté CLI condamne l'édition au prompt terminal.
        //      `readyForInput` évite en prime de taper pendant le « trust this folder ».
        if let hs = handshakeAt, instructionSentAt == nil {
            if Date().timeIntervalSince(hs) > connectSettle,
               ClaudePromptHeuristics.readyForInput(screen) {
                instructionSentAt = Date()
                progress("`claude` prêt → envoi de la consigne d'édition")
                // Texte puis Entrée **séparément** : accolés dans la même écriture, la TUI
                // absorbe le retour chariot (même contrainte qu'`InitClaudeMdCoordinator`).
                send(Self.instruction)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.send("\r")
                }
            } else if Date().timeIntervalSince(hs) > readyDeadline {
                finish(prologue: "`claude` n'a jamais paru prêt à recevoir un prompt en "
                               + "\(Int(readyDeadline)) s après le handshake — rien n'a été tapé"
                               + diagnosticHint())
            }
        }

        // (c'') Consigne partie, mais aucun aperçu : c'est LE symptôme d'une éligibilité
        //       refusée côté CLI (§2.2) — l'édition est alors passée par le prompt terminal.
        if let sent = instructionSentAt, verdictSentAt == nil,
           Date().timeIntervalSince(sent) > editDeadline {
            finish(prologue: "aucun `openDiff` reçu dans les \(Int(editDeadline)) s suivant la "
                           + "consigne" + diagnosticHint())
        }

        // (d) Après le verdict : on guette le disque, seul juge de paix.
        if let sent = verdictSentAt {
            if targetFileContainsAfterToken() {
                progress("fichier modifié sur disque — stabilisation \(Int(settleAfterWrite)) s "
                         + "avant la photo d'écran finale")
                // Le fichier a bougé ; on laisse la TUI se stabiliser avant la photo finale
                // (le point « aucun prompt » se juge sur un écran au repos).
                DispatchQueue.main.asyncAfter(deadline: .now() + settleAfterWrite) { [weak self] in
                    self?.finish(prologue: nil)
                }
                return
            }
            if Date().timeIntervalSince(sent) > applyDeadline {
                finish(prologue: nil)   // le disque n'a pas bougé : le point 7 le dira
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }

    // MARK: Lecture de l'écran

    /// Écran **visible** (les `rows` dernières lignes du buffer actif).
    ///
    /// Pourquoi pas tout le buffer : la TUI de `claude` rend **dans le buffer normal**
    /// (pas d'écran alterné), donc `getBufferAsData(.active)` renvoie aussi tout le
    /// scrollback — où traîne le « trust this folder » du démarrage, qui déclencherait à
    /// lui seul `permissionPromptVisible`. Le contrat parle d'un prompt « resté **affiché**
    /// » : c'est bien l'écran visible qu'il faut regarder.
    private func visibleScreen() -> String {
        guard let ht = terminal else { return "" }
        let raw: String = ptyQueue.sync {
            let rows = max(ht.terminal.rows, 1)
            let full = String(data: ht.terminal.getBufferAsData(kind: .active), encoding: .utf8) ?? ""
            let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(rows).joined(separator: "\n")
        }
        return Self.renderedText(raw)
    }

    /// Buffer complet (scrollback inclus) : sert au diagnostic et à la recherche des
    /// messages d'erreur du CLI, qui défilent et ne sont plus à l'écran à la fin.
    private func fullBuffer() -> String {
        guard let ht = terminal else { return "" }
        let raw: String = ptyQueue.sync {
            String(data: ht.terminal.getBufferAsData(kind: .active), encoding: .utf8) ?? ""
        }
        return Self.renderedText(raw)
    }

    /// Normalise le texte rendu par l'émulateur **avant toute recherche de sous-chaîne**.
    ///
    /// ⚠️ Ce n'est pas cosmétique, c'est indispensable — et ça a coûté deux runs à
    /// diagnostiquer. La TUI de `claude` ne pose pas d'espaces entre les mots : elle
    /// **déplace le curseur** (`CSI n G`) et écrit mot par mot. Les cellules sautées
    /// gardent `code == 0`, et `CharData.getCharacter()` rend un code 0 en **U+0000**,
    /// pas en espace. Sur un buffer brut, `contains("trust this folder")` ou
    /// `contains("1. Yes")` est donc **toujours faux** : entre les mots il y a des NUL.
    ///
    /// On remplace donc tout caractère de contrôle par une espace (sauf `\n`, qui sépare
    /// les lignes) et on réduit les suites d'espaces — le nombre de cellules sautées
    /// dépend de la largeur du terminal, il ne doit pas entrer dans l'équation.
    ///
    /// ⚠️ **Le même écueil existe en production** : `TerminalController.screenText(id:)`
    /// renvoie ce texte brut tel quel à `ClaudePromptHeuristics` (`SessionStore`,
    /// `InitClaudeMdCoordinator`) — voir le compte rendu de T10.
    private static func renderedText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var previousWasSpace = false
        for scalar in raw.unicodeScalars {
            if scalar == "\n" {
                out.append("\n")
                previousWasSpace = false
                continue
            }
            let blank = scalar.value < 0x20 || scalar.value == 0x7F || scalar == " "
            if blank {
                if previousWasSpace { continue }
                previousWasSpace = true
                out.append(" ")
            } else {
                previousWasSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func send(_ text: String) {
        guard let ht = terminal else { return }
        ptyQueue.async { ht.send(text) }
    }

    /// Noms des outils déjà appelés, dans l'ordre, tels que la TUI les affiche
    /// (`⏺ Read(fichier)`, `⏺ Glob(motif)`, `⏺ Update(fichier)` pour `Edit`…).
    ///
    /// Sert à **dater les tours** : c'est ce qui a permis d'établir que `claude` rafraîchit
    /// sa liste de clients MCP entre deux tours (une édition tardive obtient son `openDiff`
    /// même quand le pont IDE s'est connecté après le premier tour).
    private static func toolCalls(in buffer: String) -> [String] {
        var out: [String] = []
        for line in buffer.split(separator: "\n") {
            guard let dot = line.firstIndex(of: "⏺") else { continue }
            let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard let paren = rest.firstIndex(of: "(") else { continue }
            let name = String(rest[..<paren])
            guard !name.isEmpty, name.count < 24, name.allSatisfy({ $0.isLetter }) else { continue }
            out.append(name)
        }
        return out
    }

    /// Le « Quick safety check » (dossier jamais ouvert) : formulation propre à ce prompt,
    /// distincte d'un prompt de permission d'édition. Vérifié sur 2.1.220.
    private static func trustPromptVisible(_ screen: String) -> Bool {
        (screen.contains("trust this folder") || screen.contains("Quick safety check"))
            && screen.contains("No, exit")
    }

    /// Écrans qui bloquent la séquence pour une raison qui n'a rien à voir avec le contrat.
    /// Les nommer évite de rendre un `FAIL` illisible du genre « rien ne s'est passé ».
    private static func blockingScreenHint(_ screen: String) -> String? {
        if screen.contains("Select login method") || screen.contains("Sign in with")
            || (screen.contains("/login") && screen.contains("authenticat")) {
            return "`claude` demande une authentification (écran de connexion) — "
                 + "connecte-toi une fois à la main (`claude` puis `/login`) et relance."
        }
        if screen.contains("Credit balance is too low") || screen.contains("credit balance") {
            return "`claude` refuse de travailler : crédit insuffisant sur le compte."
        }
        if screen.contains("Invalid API key") {
            return "`claude` refuse la clé d'API (ANTHROPIC_API_KEY invalide dans l'environnement ?)."
        }
        return nil
    }

    // MARK: Disque

    private func targetFileContainsAfterToken() -> Bool {
        guard let f = targetFile,
              let content = try? String(contentsOf: f, encoding: .utf8) else { return false }
        return content.contains(Self.afterToken)
    }

    // MARK: Fin

    /// **Point de sortie unique.** Évalue les points qui ne peuvent l'être qu'à la fin,
    /// nettoie (process + lock + dossier), imprime, sort. Idempotent : plusieurs échéances
    /// peuvent se croiser (timeout global vs. sortie du process).
    private func finish(prologue: String?) -> Never {
        // Ré-entrance impossible en pratique (tout est sérialisé sur `main` et cette
        // fonction se termine par `exit`) ; la garde est là pour que ça reste vrai si
        // quelqu'un ajoute un chemin de sortie.
        if finished { fflush(stdout); exit(1) }
        finished = true

        let screen = visibleScreen()
        let buffer = fullBuffer()

        // Point 6 — l'acceptation à deux blocs. On ne peut pas « voir » le parsing du CLI ;
        // on constate ses deux effets observables : il n'a pas crié, et il a agi.
        // « Failed to show diff in IDE » / « Not accepted » sont EXACTEMENT ce que le CLI
        // affiche quand notre `content` ne lui convient pas (défaut D1).
        let cliComplained = buffer.contains("Failed to show diff in IDE")
            || buffer.contains("Not accepted")
        let diskChanged = targetFileContainsAfterToken()
        if verdictSentAt == nil {
            report.setIfUnset(.fileSaved, .skip, "aucun openDiff à accepter")
        } else if cliComplained {
            report.set(.fileSaved, .fail,
                       "le CLI a signalé un échec d'aperçu (« Failed to show diff in IDE » / "
                       + "« Not accepted ») → la réponse à deux blocs n'a pas été comprise")
        } else if diskChanged {
            report.set(.fileSaved, .pass,
                       "\(acceptedContentLength) o renvoyés en 2ᵉ bloc, repris par le CLI comme "
                       + "input de l'outil, aucune erreur d'aperçu dans le terminal")
        } else {
            report.set(.fileSaved, .fail,
                       "verdict émis mais le CLI n'a rien appliqué et n'a rien signalé "
                       + "— contrat ambigu, voir le buffer ci-dessous")
        }

        // Point 7 — le disque, seul signal faisant autorité (indépendant de la version).
        if let f = targetFile {
            let content = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            if content.contains(Self.afterToken) && !content.contains(Self.beforeToken) {
                report.set(.disk, .pass, "\(f.lastPathComponent) : « \(Self.beforeToken) » → « \(Self.afterToken) »")
            } else if content.contains(Self.afterToken) {
                report.set(.disk, .fail,
                           "le jeton « \(Self.afterToken) » est présent mais « \(Self.beforeToken) » "
                           + "n'a pas disparu (édition partielle)")
            } else {
                report.set(.disk, .fail,
                           "\(f.lastPathComponent) inchangé — contenu : "
                           + content.replacingOccurrences(of: "\n", with: "⏎").prefix(120))
            }
        } else {
            report.set(.disk, .skip, "pas de fichier de test")
        }

        // Point 8 — le prompt de permission ne doit PAS être resté affiché. Ne se juge que
        // si un aperçu a bien eu lieu : sans `openDiff`, l'écran n'apprend rien du contrat.
        if verdictSentAt == nil {
            report.setIfUnset(.noPrompt, .skip, "aucun openDiff : rien à conclure de l'écran")
        } else if ClaudePromptHeuristics.permissionPromptVisible(screen) {
            report.set(.noPrompt, .fail,
                       "un prompt de permission est affiché après acceptation — le CLI est "
                       + "retombé sur son propre prompt (régression du contrat)")
        } else {
            report.set(.noPrompt, .pass, "écran au repos, aucun prompt de permission")
        }

        // Points restés vierges : la séquence n'est jamais allée jusque-là.
        for p in ContractPoint.allCases { report.setIfUnset(p, .skip, "séquence interrompue avant ce point") }

        let tmpPath = tmpDir?.path ?? "?"
        cleanup()

        print("")
        // Le prologue explique **pourquoi** on s'est arrêté là. On le tait quand les huit
        // points sont verts : une échéance qui grille pendant la photo d'écran finale ne
        // doit pas faire croire à un incident sur un run par ailleurs conforme.
        if let prologue, !report.allPassed {
            print("⚠️  \(prologue)")
            print("")
        }
        print(report.render())
        if !report.allPassed {
            print("--- écran visible de `claude` à la fin -------------------------------------")
            print(screen.split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
            print("----------------------------------------------------------------------------")
            print("journal du pont : \(keptLogPath ?? IDELog.fileURL.path)"
                  + (keepArtifacts ? "   (dossier conservé : \(tmpPath))"
                                   : "   (dossier de test supprimé : \(tmpPath))"))
        }
        let ok = report.allPassed
        // Version **annoncée par le CLI** en priorité (c'est celle du process qui vient de
        // parler) ; à défaut celle du binaire lancé.
        let version = announcedVersion ?? claudeVersion
        print("=== \(report.passCount)/\(ContractPoint.allCases.count) points — "
              + (ok ? "PASS" : "FAIL") + " (claude \(version), contrat validé pour "
              + "\(IDEProtocolContract.lastValidatedClaudeVersion)) ===")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    /// Ne laisse **rien** derrière : ni process, ni lock, ni dossier. Appelé sur tous les
    /// chemins de sortie, y compris les échecs et les signaux.
    private func cleanup() {
        // 1. Le `claude` de CE test, et lui seul, par le pid retenu au spawn. D'abord son
        //    groupe (il a `setsid`é dans le PTY, donc pgid == pid) pour emporter ses
        //    sous-process, puis lui-même. Jamais de `pkill`/recherche par nom : le poste
        //    fait tourner d'autres agents `claude` de l'utilisateur.
        if claudePid > 0 {
            kill(-claudePid, SIGKILL)
            kill(claudePid, SIGKILL)
            claudePid = 0
        }
        terminal = nil
        // 2. Listener + lock (`stop()` supprime le fichier `<port>.lock`).
        host?.stop()
        host = nil
        // 3. Le dossier jetable. On garde le journal du pont s'il y a été redirigé : on le
        //    recopie à côté avant de tout effacer, sinon le diagnostic partirait avec.
        if let dir = tmpDir, !keepArtifacts {
            // Transcription d'abord : son nom se déduit du chemin **réel** du dossier, qu'on
            // ne peut plus calculer une fois celui-ci supprimé.
            removeClaudeTranscript(for: dir)
            let log = IDELog.fileURL
            if log.path.hasPrefix(dir.path) {
                let keep = Self.scratchRoot().appendingPathComponent("potof-ide-selftest.log")
                try? FileManager.default.removeItem(at: keep)
                try? FileManager.default.copyItem(at: log, to: keep)
                keptLogPath = keep.path
            }
            try? FileManager.default.removeItem(at: dir)
            tmpDir = nil
        }
    }

    /// Supprime la transcription que `claude` a écrite pour NOTRE dossier jetable.
    ///
    /// Le CLI archive chaque session sous `~/.claude/projects/<cwd encodé>` (séparateurs,
    /// `_` et `.` remplacés par `-`). Sans ce ménage, chaque exécution du selftest laisserait
    /// un dossier mort de plus chez l'utilisateur.
    ///
    /// ⚠️ L'encodage part du **realpath**, pas de `resolvingSymlinksInPath()` : sur macOS
    /// ce dernier ne déplie PAS `/var` → `/private/var` (vérifié), alors que `claude`, lui,
    /// enregistre le cwd déplié. On essaie donc les deux formes. Garde-fou pour ne rien
    /// effacer d'autre : le nom doit contenir notre préfixe (qui porte un UUID de run).
    ///
    /// On ne touche **pas** à `~/.claude.json`, où le CLI ajoute aussi une entrée
    /// `projects` : ce fichier est réécrit en permanence par les autres agents du poste,
    /// un lire-modifier-réécrire de notre part écraserait leur travail.
    private func removeClaudeTranscript(for dir: URL) {
        var candidates = [dir.path]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(dir.path, &buf) != nil { candidates.append(String(cString: buf)) }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        for path in Set(candidates) {
            let encoded = path
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            guard encoded.contains("potof-ide-selftest-") else { continue }
            let url = root.appendingPathComponent(encoded, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            IDELog.log("selftest: transcription \(url.lastPathComponent) supprimée")
        }
    }

    /// Chemin où le journal du pont a été mis à l'abri avant la suppression du dossier
    /// jetable (nil si `--keep`, ou si le journal vivait déjà ailleurs).
    private var keptLogPath: String?

    /// Ctrl-C / `kill` pendant le test : on veut quand même le nettoyage. `SIG_IGN` puis
    /// une `DispatchSourceSignal` — le handler C ne pourrait pas toucher à cet état.
    private func installSignalTraps() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.finish(prologue: "interrompu par un signal (\(sig))")
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Impression

    private func printHeaderPrologue() {
        print("=== Auto-test du contrat IDE — Potof Toolkit (T10) ===")
    }

    private func printHeader() {
        print("binaire claude : \(claudePath) (\(claudeVersion))")
        print("contrat validé : \(IDEProtocolContract.lastValidatedClaudeVersion)")
        print("dossier de test: \(tmpDir?.path ?? "?")")
        print("hôte isolé     : 127.0.0.1:\(host?.port.map(String.init) ?? "?")"
              + "   lock \(host?.lockURL?.path ?? "?")")
        print("journal du pont: \(IDELog.fileURL.path)")
        print("délai global   : \(Int(globalTimeout)) s")
        print("")
        fflush(stdout)
    }

    /// Rappel des causes d'échec « hors contrat » les plus fréquentes, joint aux prologues
    /// d'échec pour éviter le faux diagnostic « le protocole a changé ».
    private func diagnosticHint() -> String {
        "\n   Pistes : `claude` non authentifié · un autre IDE publie un lock concurrent "
        + "(l'auto-connexion se neutralise, mais CLAUDE_CODE_SSE_PORT devrait primer) · "
        + "`diffTool` ≠ \"auto\" dans les réglages Claude · le modèle a choisi un autre outil "
        + "qu'Edit/Write (seuls éligibles, §2.2) · le tour a démarré AVANT la connexion du "
        + "client « ide » (cf. `instruction` : c'est ce que fait un prompt passé en argv)."
    }

    // MARK: Emplacements

    /// Racine des fichiers jetables. **Jamais `/tmp`** (cf. instructions du projet) :
    /// `POTOF_SELFTEST_DIR` si fourni, sinon le dossier temporaire *par utilisateur*
    /// (`/var/folders/…/T`). Les deux sont **hors `$HOME`**, et c'est délibéré : un dossier
    /// de test sous `$HOME` serait couvert par le lock de l'app installée, ce qui ferait
    /// deux IDE valides pour le même cwd (§2.1) — `CLAUDE_CODE_SSE_PORT` prime, mais autant
    /// ne pas dépendre de cette subtilité.
    private static func scratchRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["POTOF_SELFTEST_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// Résolution du binaire, du plus explicite au plus coûteux. On écarte volontairement
    /// les emballages de `~/.superset/bin` (un script qui ne fait que `exec` le vrai
    /// binaire) : le banc de test ne doit rien devoir à Superset.
    private static func locateClaude() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let forced = ProcessInfo.processInfo.environment["POTOF_SELFTEST_CLAUDE"] {
            candidates.append(forced)
        }
        candidates.append(home + "/.local/bin/claude")       // installeur natif
        candidates.append(home + "/.claude/local/claude")    // installeur historique
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let d = String(dir)
            if d.hasPrefix(home + "/.superset") { continue }
            candidates.append(d + "/claude")
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // Dernier recours : PATH complet d'un shell de **login** (`.zprofile`, Homebrew, nvm…),
        // exactement la raison pour laquelle les sessions embarquées passent par `$SHELL -l`.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = runCapturing(shell, ["-l", "-c", "command -v claude"]),
           fm.isExecutableFile(atPath: out) { return out }
        return nil
    }

    private static func claudeVersion(at path: String) -> String? {
        // `claude --version` → « 2.1.220 (Claude Code) » : on garde le premier champ.
        runCapturing(path, ["--version"])?.split(separator: " ").first.map(String.init)
    }

    private static func runCapturing(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// Sortie « avant même d'avoir commencé » : aucun point n'a pu être évalué, on le dit
    /// et on nettoie ce qui aurait déjà été créé.
    private func fail(prologue: String) -> Never {
        finish(prologue: prologue)
    }
}
