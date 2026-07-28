import Foundation
import Combine
import Network

/// **Hôte IDE global de l'app** : un seul port, un seul lock, N connexions.
///
/// Là où `IDEServer` sert **une** session possédée (port injecté dans l'env du shell
/// au spawn), `IDEHost` sert les agents **externes** — ceux que l'app ne lance pas :
/// un `claude` démarré par Superset dans son propre PTY, ou n'importe quel terminal
/// du poste. Ces agents n'ont aucun `CLAUDE_CODE_SSE_PORT` : leur seul moyen de nous
/// trouver est le **scan de `~/.claude/ide/*.lock`**, dont le matching se fait par
/// **préfixe de chemin** sur `workspaceFolders` — d'où un lock unique couvrant `$HOME`
/// plutôt qu'un lock par dossier.
///
/// Deux conséquences du contrat (vérifiées, cf. `IDEProtocolContract`) qui dictent la
/// forme de cette classe :
/// - `claude` ne s'auto-connecte que s'il trouve **exactement un** IDE valide → un
///   seul lock à nous, et un autre IDE actif sur le même arbre neutralise tout ;
/// - l'auto-connexion n'est tentée que **pendant les 30 premières secondes** du CLI →
///   l'hôte doit être debout avant l'agent (d'où un démarrage en `applicationDidFinishLaunching`).
///
/// Singleton app-level : l'état est adossé à des connexions réseau vivantes, il ne
/// doit jamais dépendre du cycle de vie d'une vue (invariant du projet).
///
/// **Thread** : tout l'état de cette classe (`clients`, `connections`, `port`, `token`)
/// est lu et muté **sur le thread principal, exclusivement** — les seams des connexions
/// arrivent sur la file réseau et sont systématiquement remarshalés. Seules les E/S
/// socket (le `NWListener` et chaque `IDEConnection`) tournent sur `netQueue`, et les
/// shell-outs d'identification sur `identityQueue` (jamais sur `main` : `lsof`/`git`
/// bloqueraient l'UI). Pas d'annotation de concurrence (le projet n'en utilise aucune).
final class IDEHost: ObservableObject {

    static let shared = IDEHost()

    /// Clients connectés, dans l'ordre d'arrivée. Alimente la liste « clients
    /// connectés » des réglages et le libellé d'origine des demandes de revue.
    @Published private(set) var clients: [IDEHostClient] = []

    /// Port réellement servi, `nil` tant que l'hôte n'est pas démarré (ou si la
    /// réservation a échoué → pas d'hôte, l'app fonctionne quand même).
    ///
    /// `@Published` pour que le panneau de diagnostic (`IDEHostStatusView`) reflète
    /// immédiatement un démarrage, un arrêt ou un changement de périmètre — muté
    /// uniquement sur le thread principal, comme tout le reste de la classe.
    @Published private(set) var port: UInt16?

    /// Périmètre publié dans `workspaceFolders`.
    ///
    /// **Piloté par le réglage `ideHost.scope`** (`IDEHostSettings`) : la valeur initiale
    /// n'est qu'un miroir du réglage persisté, et `start()` / `applyCurrentScope()` la
    /// réaffectent depuis lui. Le matching côté `claude` étant par **préfixe de chemin**
    /// (vérifié en 2.1.220), un seul dossier couvre toute son arborescence — d'où un
    /// périmètre exprimé en un ou deux chemins racines plutôt qu'une énumération.
    ///
    /// L'écrire ne republie **pas** toute seule (une republication est un effet de bord
    /// sur le disque) : l'appelant enchaîne explicitement sur `republishLock()`. En
    /// pratique, passer par `applyCurrentScope()` fait les deux dans le bon ordre.
    var servedFolders: [URL] = IDEHostSettings.shared.scope.servedFolders

    /// `true` si le listener est debout (donc si le lock est publié).
    var isRunning: Bool { listener != nil }

    /// Token d'auth du lock. **Jamais journalisé** : c'est la seule barrière au-delà du
    /// binding `127.0.0.1`, et le périmètre `$HOME` élargit la surface (n'importe quel
    /// process local peut tenter la connexion).
    private var token: String?
    private var listener: NWListener?
    /// Connexions vivantes, indexées par l'id du client (= id d'origine des demandes).
    private var connections: [UUID: IDEConnection] = [:]

    private let netQueue = DispatchQueue(label: "com.potof.toolkit.ide.host")
    private let identityQueue = DispatchQueue(label: "com.potof.toolkit.ide.host.identity")

    private init() {}

    // MARK: - Cycle de vie

    /// Réserve un port éphémère, ouvre le listener sur `127.0.0.1` et publie le lock.
    ///
    /// Dégradation silencieuse : si la réservation du port ou l'ouverture du listener
    /// échoue, l'app démarre **sans** hôte IDE (les agents externes retomberont sur le
    /// prompt de permission de leur terminal). On journalise, on ne bloque rien.
    ///
    /// Le périmètre vient du réglage `ideHost.scope` (et non plus d'un défaut codé en
    /// dur) : un utilisateur qui a coupé l'hôte au run précédent ne doit pas le voir
    /// revenir au lancement suivant.
    func start() {
        guard listener == nil else { return }   // idempotent

        let scope = IDEHostSettings.shared.scope
        servedFolders = scope.servedFolders
        guard scope.publishesLock else {
            // « Désactivé » : ni lock ni listener. Rien à dégrader — les agents externes
            // gardent le prompt de permission de leur terminal, et les sessions possédées
            // du Claude Launcher ont leur propre `IDEServer` (port injecté).
            IDELog.log("hôte IDE : périmètre « \(scope.title) » → aucun lock publié, hôte inactif")
            return
        }

        guard let port = Self.reserveEphemeralPort() else {
            IDELog.log("hôte IDE : aucun port éphémère disponible → hôte désactivé")
            return
        }
        let token = Self.makeToken()

        do {
            // TCP nu : le handshake WebSocket est fait à la main par `IDEConnection`
            // (il faut lire l'en-tête d'auth et écho le sous-protocole `mcp`, deux
            // choses hors de portée de `NWProtocolWebSocket` côté serveur).
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)   // loopback SEULEMENT
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] nwc in
                guard let self else { nwc.cancel(); return }
                // Remarshalage immédiat : l'enregistrement du client touche de l'état
                // `@Published`. La `NWConnection` n'est démarrée qu'ensuite (elle ne
                // lit rien tant que `start` n'est pas appelé, le noyau tamponne).
                DispatchQueue.main.async { self.accept(nwc) }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { IDELog.log("hôte IDE : listener \(port) en échec: \(e)") }
            }
            l.start(queue: netQueue)
            self.listener = l
            self.port = port
            self.token = token
        } catch {
            IDELog.log("hôte IDE : ouverture du listener impossible: \(error) → hôte désactivé")
            return
        }

        writeLock()
        IDELog.log("hôte IDE prêt sur 127.0.0.1:\(port) — périmètre \(servedFolders.map(\.path))")
        logCompetingLocks(excluding: port)
    }

    /// Ferme le listener, coupe les connexions et **supprime le lock** (un lock qui
    /// survit à l'app ferait échouer la connexion des agents suivants : `claude` ne
    /// purge que les locks dont le pid est mort, et un pid recyclé passerait au
    /// travers).
    ///
    /// ⚠️ **Entièrement synchrone** : appelée depuis `applicationWillTerminate`, elle
    /// ne peut pas compter sur un `DispatchQueue.main.async` (le run loop ne tournera
    /// plus). D'où l'ordre : lock d'abord (plus personne ne nous découvre), puis
    /// listener, puis purge des demandes en vol, puis coupure des sockets.
    func stop() {
        removeLock()

        listener?.cancel()
        listener = nil

        let doomed = connections
        connections.removeAll()
        // Origines calculées AVANT de vider `clients` (le libellé se lit dedans).
        let orphaned = clients.map { origin(for: $0.id) }
        clients.removeAll()

        // Aucune demande orpheline : chaque `openDiff` est un appel BLOQUANT côté CLI,
        // il doit recevoir une réponse même quand c'est nous qui partons. Le centre
        // refuse tout ce qu'il retire sans verdict explicite.
        for origin in orphaned { DiffReviewCenter.shared.dropAll(origin: origin) }
        // Coupure APRÈS la purge : les complétions écrivent encore sur un socket vivant
        // (dans le meilleur des cas l'agent reçoit un vrai `DIFF_REJECTED` au lieu d'un
        // échec de transport).
        for (_, conn) in doomed { conn.cancel() }

        port = nil
        token = nil
        IDELog.log("hôte IDE arrêté (lock supprimé, \(doomed.count) connexion(s) coupée(s))")
    }

    /// Réécrit le lock à chaud sans couper les connexions en cours — utilisé quand le
    /// périmètre servi change (réglage `ideHost.scope`).
    ///
    /// Le **token est conservé** : le changer invaliderait un agent qui a déjà lu le
    /// lock et n'a pas encore ouvert sa WebSocket (fenêtre de 30 s au démarrage du CLI).
    func republishLock() {
        guard isRunning else { return }
        writeLock()
        IDELog.log("hôte IDE : lock republié — périmètre \(servedFolders.map(\.path))")
    }

    /// Aligne l'hôte sur le réglage `ideHost.scope` courant. **Sur `main`.**
    ///
    /// Point d'entrée unique du changement de périmètre à chaud (appelé par le `didSet`
    /// de `IDEHostSettings.scope`, et sûr à rappeler à tout moment) :
    ///
    /// | Réglage | Hôte debout | Hôte arrêté |
    /// |---|---|---|
    /// | `allHome` / `supersetWorktrees` | `servedFolders` + `republishLock()` | `start()` |
    /// | `disabled` | `stop()` (lock supprimé) | rien |
    ///
    /// **Les connexions en cours ne sont pas coupées** lors d'un simple rétrécissement du
    /// périmètre : le lock ne sert qu'à la **découverte**. Un agent déjà connecté garde sa
    /// WebSocket même si son `cwd` sort du nouveau périmètre — et c'est voulu, le couper
    /// laisserait ses `openDiff` en vol sans réponse alors que l'appel est bloquant.
    /// Le nouveau périmètre ne s'applique donc qu'aux agents **à venir**.
    ///
    /// « Désactivé » est le seul cas qui coupe, puisqu'il n'y a plus d'hôte du tout ;
    /// `stop()` rend alors un `DIFF_REJECTED` propre à chaque demande en vol plutôt que
    /// de laisser des agents figés.
    func applyCurrentScope() {
        let scope = IDEHostSettings.shared.scope
        guard scope.publishesLock else {
            guard isRunning else { return }         // déjà coupé : rien à faire
            IDELog.log("hôte IDE : périmètre « \(scope.title) » → arrêt de l'hôte")
            stop()
            return
        }
        servedFolders = scope.servedFolders
        if isRunning {
            republishLock()   // même port, même token, même fichier de lock réécrit
        } else {
            // Retour depuis « désactivé » : nouveau port éphémère et nouveau token
            // (l'ancien lock avait été supprimé par `stop()`, rien à nettoyer).
            start()
        }
    }

    // MARK: - Connexions

    /// Enregistre une connexion entrante et câble ses seams. Sur `main`.
    ///
    /// Le client n'est publié dans `clients` qu'au **handshake réussi** (donc après
    /// validation du token) : une tentative refusée en 401 ne doit pas apparaître dans
    /// l'UI ni compter comme un agent connecté.
    private func accept(_ nwc: NWConnection) {
        // `stop()` a pu passer entre l'arrivée du socket et ce remarshalage : sans
        // listener ni token, on ne sert plus personne.
        guard let token, listener != nil else { nwc.cancel(); return }

        let clientID = UUID()
        let conn = IDEConnection(
            nwc: nwc,
            token: token,
            // `workspace` ne sert qu'à répondre `getWorkspaceFolders` : on annonce le
            // périmètre servi, pas le cwd de l'agent (qu'on ne connaît pas encore).
            workspace: servedFolders.first ?? FileManager.default.homeDirectoryForCurrentUser,
            handlers: makeHandlers(clientID: clientID))
        connections[clientID] = conn

        conn.onHandshake = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.connections[clientID] != nil else { return }
                self.clients.append(
                    IDEHostClient(id: clientID, identity: .unknown, connectedAt: Date()))
                IDELog.log("hôte IDE : client connecté (\(self.clients.count) au total)")
            }
        }
        conn.onClose = { [weak self] in
            DispatchQueue.main.async { self?.forget(clientID) }
        }
        // Seams fournis par `IDEConnection` (T1). Ils arrivent depuis la file de la
        // connexion → remarshalage systématique avant de toucher à l'état publié.
        conn.onClientPID = { [weak self] pid in
            guard let self else { return }
            self.identityQueue.async { [weak self] in
                // `resolve` fait un shell-out (`lsof`, puis `git`) : hors thread
                // principal. Seule la MUTATION revient sur `main`.
                let identity = IDEClientIdentity.resolve(pid: pid, fallbackFilePath: nil)
                DispatchQueue.main.async { self?.setIdentity(identity, for: clientID) }
            }
        }
        conn.onClientHello = { name, version in
            DispatchQueue.main.async {
                IDELog.log("hôte IDE : clientInfo \(name ?? "?") \(version ?? "?")")
                // Empreinte de version (informatif) : `IDEContractGuard` la compare à
                // `IDEProtocolContract.lastValidatedClaudeVersion`.
                IDEContractGuard.shared.noteClaudeVersion(version)
            }
        }

        conn.start(queue: netQueue)
    }

    /// Le client a disparu (socket fermé, agent tué, `claude` quitté) : plus personne
    /// au bout du fil pour lire nos réponses → on purge **ses** demandes en attente.
    /// Idempotent (une `NWConnection` peut notifier `failed` puis `cancelled`).
    private func forget(_ clientID: UUID) {
        let known = connections.removeValue(forKey: clientID) != nil
        let wasClient = clients.contains { $0.id == clientID }
        guard known || wasClient else { return }
        let origin = origin(for: clientID)
        clients.removeAll { $0.id == clientID }
        DiffReviewCenter.shared.dropAll(origin: origin)
        IDELog.log("hôte IDE : client déconnecté (\(clients.count) restant(s))")
    }

    /// Handlers d'une connexion. `IDEConnection` les appelle depuis sa file → chacun
    /// remarshale sur `main` avant de lire `clients` ou de toucher au centre de revue.
    private func makeHandlers(clientID: UUID) -> IDEDiffHandlers {
        IDEDiffHandlers(
            openDiff: { [weak self] req, done in
                DispatchQueue.main.async {
                    guard let self else { done(.rejected); return }
                    self.enqueueDiff(req, clientID: clientID, done: done)
                }
            },
            closeTab: { [weak self] tabName in
                DispatchQueue.main.async {
                    guard let self else { return }
                    DiffReviewCenter.shared.dismiss(matchingTab: tabName,
                                                    origin: self.origin(for: clientID))
                }
            },
            closeAllTabs: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    DiffReviewCenter.shared.dismiss(matchingTab: nil,
                                                    origin: self.origin(for: clientID))
                }
            })
    }

    /// Enfile une demande de revue pour le compte de `clientID`. Sur `main`.
    ///
    /// Si l'identité n'est pas encore résolue (premier `openDiff` arrivé avant la
    /// notification `ide_connected`, ou pid non fourni), on la résout d'abord — hors
    /// `main` — en s'aidant du **chemin du fichier** de la demande comme repli, pour ne
    /// pas afficher « Agent externe » alors qu'on peut faire mieux.
    private func enqueueDiff(_ req: IDEDiffRequest,
                             clientID: UUID,
                             done: @escaping (IDEDiffVerdict) -> Void) {
        guard let client = clients.first(where: { $0.id == clientID }) else {
            // Client déjà oublié : personne ne lira la réponse, mais on la rend quand
            // même (l'appel est bloquant) plutôt que de laisser une demande orpheline.
            done(.rejected)
            return
        }
        if client.identity.cwd != nil {   // identité déjà résolue : chemin nominal
            DiffReviewCenter.shared.enqueue(request: req, origin: origin(for: clientID), complete: done)
            return
        }
        let pid = client.identity.pid
        identityQueue.async { [weak self] in
            let identity = IDEClientIdentity.resolve(pid: pid, fallbackFilePath: req.oldPath)
            DispatchQueue.main.async {
                // Re-vérification : la connexion a pu tomber pendant la résolution.
                // Sans ce garde-fou, `forget` serait déjà passé et la demande enfilée
                // juste après resterait orpheline dans la file de revue.
                guard let self, self.clients.contains(where: { $0.id == clientID }) else {
                    done(.rejected)
                    return
                }
                self.setIdentity(identity, for: clientID)
                DiffReviewCenter.shared.enqueue(request: req,
                                                origin: self.origin(for: clientID),
                                                complete: done)
            }
        }
    }

    /// Met à jour l'identité publiée d'un client. Sur `main`.
    private func setIdentity(_ identity: IDEClientIdentity, for clientID: UUID) {
        guard let i = clients.firstIndex(where: { $0.id == clientID }) else { return }
        clients[i].identity = identity
        // Le cwd résolu est le VRAI espace de travail de l'agent. Tant qu'on ne le
        // connaissait pas, `getWorkspaceFolders` annonçait le périmètre servi ($HOME) —
        // ce qui laisserait `claude` croire que la racine de son projet est le dossier
        // utilisateur. On corrige dès que possible.
        if let cwd = identity.cwd { connections[clientID]?.updateWorkspace(cwd) }
        IDELog.log("hôte IDE : client identifié — \(identity.label)")
    }

    /// Origine d'une demande venant de ce client. `kind` est l'identité **stable**
    /// (c'est sur elle que le centre apparie ses purges) ; `label` n'est que de
    /// l'affichage et peut encore être générique au tout premier `openDiff`.
    private func origin(for clientID: UUID) -> DiffReviewOrigin {
        let label = clients.first { $0.id == clientID }?.identity.label
            ?? IDEClientIdentity.unknown.label
        return DiffReviewOrigin(kind: .externalClient(clientID), label: label)
    }

    // MARK: - Lock file

    /// Écrit `~/.claude/ide/<port>.lock`, le seul moyen pour un `claude` externe de
    /// nous découvrir. Forme exacte attendue par le CLI (vérifiée en 2.1.220) :
    /// le **port est le nom du fichier**, le contenu porte le périmètre et le token.
    private func writeLock() {
        guard let port, let token else { return }
        let lock: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": servedFolders.map(\.path),
            "ideName": IDEProtocolContract.ideName,
            "transport": "ws",              // → `useWebSocket` côté CLI
            "runningInWindows": false,
            "authToken": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: lock) else {
            IDELog.log("hôte IDE : sérialisation du lock impossible")
            return
        }
        let dir = Self.lockDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent("\(port).lock"))
        } catch {
            IDELog.log("hôte IDE : écriture du lock impossible: \(error)")
        }
    }

    private func removeLock() {
        guard let port else { return }
        try? FileManager.default.removeItem(at: Self.lockDir.appendingPathComponent("\(port).lock"))
    }

    /// Diagnostic (log uniquement, aucune action) : `claude` ne s'auto-connecte que
    /// s'il trouve **exactement un** IDE valide. Un autre lock **vivant** couvrant le
    /// même arbre — un autre IDE, ou une seconde instance de Potof lancée avec
    /// `open -n` pour un test — neutralise l'auto-connexion des deux côtés. La
    /// détection fine et l'avertissement dans l'UI sont l'objet de T12.
    private func logCompetingLocks(excluding port: UInt16) {
        let mine = "\(port).lock"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.lockDir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "lock" {
            guard url.lastPathComponent != mine,
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  kill(pid_t(pid), 0) == 0 else { continue }   // ESRCH ⇒ lock mort, ignoré
            IDELog.log("⚠️ hôte IDE : lock concurrent VIVANT « \(obj["ideName"] as? String ?? "?") » "
                       + "sur \(obj["workspaceFolders"] as? [String] ?? []) — l'auto-connexion "
                       + "de `claude` est neutralisée sur les dossiers couverts par les deux")
        }
    }

    // MARK: - Statique

    static var lockDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ide", isDirectory: true)
    }

    /// Réserve un port éphémère libre : bind à `127.0.0.1:0`, lit le port attribué,
    /// referme. Fenêtre de course minuscule (localhost mono-utilisateur) — acceptable.
    /// Jumeau de l'implémentation privée d'`IDEServer` : les deux fusionneront quand
    /// les sessions possédées basculeront sur l'hôte (hors périmètre ici).
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

    /// 256 bits d'aléa opaque, en hexadécimal. `SystemRandomNumberGenerator` est
    /// adossé au CSPRNG du système sur Darwin. Le périmètre `$HOME` expose l'hôte à
    /// tout process local : ce token est la seule chose qui l'en sépare.
    private static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(64)
        for _ in 0..<32 {
            out += String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &rng))
        }
        return out
    }
}

/// Un `claude` externe connecté à l'hôte. `identity` est **mutable** : elle démarre
/// inconnue et se précise quand la notification `ide_connected {pid}` arrive (puis
/// résolution du cwd → worktree → branche, cf. `IDEClientIdentity`).
struct IDEHostClient: Identifiable {
    let id: UUID
    var identity: IDEClientIdentity
    let connectedAt: Date
}
