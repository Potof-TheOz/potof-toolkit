import AppKit
import Combine
import UserNotifications

/// Propriétaire unique du câblage des notifications Claude (niveau app).
///
/// Reçoit les events du `NotificationChannel`, alimente la cloche (`NotificationBus`),
/// pose la pastille + fait rebondir l'icône du Dock, et affiche une **bannière macOS
/// native** (sauf anti-spam). Route les clics (bannière ou ligne de cloche) vers le
/// focus de la bonne session, via deux coutures découplées :
///   - `NotificationSessionProviding` : l'outil possédant les sessions s'enregistre ;
///   - `focusRequests` (Combine) : `RootView` bascule l'outil affiché.
///
/// Singleton comme `TerminalController.shared` (l'app n'héberge qu'un ClaudeLauncher).
/// Toutes les méthodes touchant l'UI/Dock/bus s'exécutent sur le **thread principal**
/// (events du canal dispatchés sur `.main`, enregistrements depuis `onAppear`).
final class NotificationCenterCoordinator: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationCenterCoordinator()

    /// Cloche du header (déplacée depuis `RootView`).
    let bus = NotificationBus()
    /// Émis au clic : `RootView` s'y abonne pour basculer `selection`.
    let focusRequests = PassthroughSubject<FocusRequest, Never>()

    private struct Registration {
        let toolID: Tool.ID
        weak var provider: NotificationSessionProviding?
    }
    private var registrations: [Registration] = []

    /// Non-lus **depuis la dernière consultation** (pastille Dock). Distinct de
    /// `bus.count`, qui est le nombre d'items encore listés dans le popover.
    private var unreadCount = 0
    private var started = false

    private lazy var channel = NotificationChannel { [weak self] event in
        self?.ingest(event)
    }

    /// `UNUserNotificationCenter` exige un vrai bundle (lit `bundleProxyForCurrentProcess`) :
    /// sous `swift run` (exécutable nu) il crasherait. Même garde que
    /// `AppDelegate.applyDockIcon`. Cloche + pastille + rebond Dock marchent quand même.
    private let canUseUN = Bundle.main.bundleURL.pathExtension == "app"

    // MARK: - Cycle de vie

    func start() {
        guard !started else { return }
        started = true

        if canUseUN {
            let center = UNUserNotificationCenter.current()
            center.delegate = self       // avant l'autorisation : capte un lancement-par-clic
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)

        channel.start()
    }

    func stop() {
        channel.stop()
        NotificationCenter.default.removeObserver(self)
        started = false
    }

    // MARK: - Enregistrement des fournisseurs de sessions

    func registerSessionProvider(_ provider: NotificationSessionProviding, toolID: Tool.ID) {
        registrations.removeAll { $0.provider == nil || $0.provider === provider }
        registrations.append(Registration(toolID: toolID, provider: provider))
    }

    func unregisterSessionProvider(_ provider: NotificationSessionProviding) {
        registrations.removeAll { $0.provider == nil || $0.provider === provider }
    }

    // MARK: - Pastille Dock

    func markNotificationsSeen() {
        unreadCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    @objc private func appDidBecomeActive() { markNotificationsSeen() }

    // MARK: - Clic (bannière OU ligne de cloche)

    func handleClick(sessionID: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        markNotificationsSeen()
        guard let sid = sessionID else { return }
        // Owner = l'outil qui possède cette session ; sinon l'unique outil enregistré
        // (permet de basculer d'outil même pour une session déjà morte).
        let owner = registrations.first { $0.provider?.containsSession(sid) == true }
            ?? registrations.first { $0.provider != nil }
        guard let owner else { return }
        focusRequests.send(FocusRequest(sessionID: sid, toolID: owner.toolID))
        owner.provider?.focusSession(sid)   // no-op si la session n'existe plus
    }

    // MARK: - Pipeline par event

    private func ingest(_ e: ChannelEvent) {
        let sid = UUID(uuidString: e.potofSessionId)
        let kind = Self.kind(event: e.event, notificationType: e.notificationType,
                             lastMessage: e.lastMessage)
        let project = Self.projectName(cwd: e.cwd)
        // Corps : le `message` de l'event, sinon le dernier message de Claude (question sur Stop).
        let bodyText = (e.message?.isEmpty == false) ? e.message : e.lastMessage
        let (title, body) = Self.content(kind: kind, project: project, message: bodyText)
        let date = e.ts.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        // a. Toujours alimenter la cloche.
        bus.ingest(AppNotification(id: UUID(), sessionID: sid, kind: kind,
                                   title: title, body: body, date: date))

        // b. Pastille Dock.
        unreadCount += 1
        NSApp.dockTile.badgeLabel = String(unreadCount)

        // c. Rebond du Dock (ignoré par macOS quand l'app est déjà active).
        //    Attente/permission = rebond insistant ; tâche terminée = rebond simple.
        NSApp.requestUserAttention(kind == .finished ? .informationalRequest : .criticalRequest)

        // d. Bannière native, sauf si on regarde déjà cette session.
        let owner = sid.flatMap { id in
            registrations.first { $0.provider?.containsSession(id) == true }
        }
        let suppress = NSApp.isActive && sid != nil && owner?.provider?.activeSessionID == sid
        if !suppress && canUseUN {
            postBanner(title: title, body: body, sessionID: sid, toolID: owner?.toolID)
        }
    }

    private func postBanner(title: String, body: String, sessionID: UUID?, toolID: Tool.ID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var info: [String: String] = [:]
        if let sessionID {
            info["sessionID"] = sessionID.uuidString
            content.threadIdentifier = sessionID.uuidString   // groupe les bannières d'une session
        }
        if let toolID { info["toolID"] = toolID }
        content.userInfo = info
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func projectName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "projet" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Classe l'event en `Kind` :
    /// - `permission_prompt` → autorisation ;
    /// - `Stop` dont le dernier message se termine par « ? » → question (attente) ;
    ///   sinon → tâche terminée ;
    /// - autre `Notification` (`idle_prompt`, `agent_needs_input`…) → attente.
    ///
    /// Note : dans les versions actuelles, une question de Claude arrive comme un
    /// `Stop` (pas d'`idle_prompt`), d'où l'heuristique sur `last_assistant_message`.
    private static func kind(event: String, notificationType: String?,
                             lastMessage: String?) -> AppNotification.Kind {
        if notificationType == "permission_prompt" { return .permission }
        if event == "Stop" { return isQuestion(lastMessage) ? .waiting : .finished }
        return .waiting
    }

    private static func isQuestion(_ text: String?) -> Bool {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
        else { return false }
        return t.hasSuffix("?") || t.hasSuffix("？")
    }

    /// Libellés inspirés de `claude-notify.js`, différenciés par type.
    private static func content(kind: AppNotification.Kind, project: String,
                                message: String?) -> (String, String) {
        switch kind {
        case .finished:
            return ("✅ Claude a terminé — \(project)", "Tâche terminée dans \(project)")
        case .permission:
            // `permission_prompt` couvre approbation d'outil ET question à choix
            // interactive (indistinguables) ; le message est toujours générique →
            // libellé neutre côté app.
            return ("🔔 Claude attend ton action — \(project)",
                    "Une autorisation ou un choix t'attend dans le terminal.")
        case .waiting:
            return ("💬 Claude attend une réponse — \(project)",
                    snippet(message) ?? "Claude attend ta réponse")
        }
    }

    /// Normalise un message multi-lignes en une ligne tronquée (~140 car.).
    private static func snippet(_ text: String?, max: Int = 140) -> String? {
        guard let t = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " "),
              !t.isEmpty else { return nil }
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Sans ça, macOS masque les bannières quand l'app est au premier plan.
        // L'anti-spam a déjà filtré à l'émission.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sid = (info["sessionID"] as? String).flatMap { UUID(uuidString: $0) }
        DispatchQueue.main.async { [weak self] in
            self?.handleClick(sessionID: sid)
            completionHandler()
        }
    }
}
