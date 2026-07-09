import Foundation

/// Une ligne du canal JSONL écrite par le hook `claude-notify.js`.
struct ChannelEvent: Decodable {
    let potofSessionId: String
    /// `hook_event_name` : `"Stop"`, `"Notification"`, …
    let event: String
    /// `notification_type` de l'event `Notification` : `"permission_prompt"`,
    /// `"idle_prompt"`, `"agent_needs_input"`… (absent pour `Stop`).
    let notificationType: String?
    let message: String?
    /// `last_assistant_message` d'un event `Stop` : sert à repérer une question.
    let lastMessage: String?
    let cwd: String?
    /// Horodatage epoch en **millisecondes** (`Date.now()` côté hook).
    let ts: Double?
}

/// Surveille le fichier JSONL de notifications et appelle `onEvent` (sur le thread
/// **principal**) pour chaque nouvelle ligne complète.
///
/// Transport 100 % local (aucun réseau, cf. CLAUDE.md) : le hook Claude append des
/// lignes, l'app les lit via un `DispatchSource` vnode. Voir `docs/NOTIFICATIONS.md`.
final class NotificationChannel {

    /// `~/Library/Application Support/PotofToolkit/notifications.jsonl`.
    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PotofToolkit", isDirectory: true)
            .appendingPathComponent("notifications.jsonl", isDirectory: false)
    }

    private let onEvent: (ChannelEvent) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var reopening = false

    init(onEvent: @escaping (ChannelEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Crée le dossier/fichier si besoin, **tronque** le backlog (les vieilles
    /// lignes réfèrent des sessions mortes : jamais persistées, les rejouer serait
    /// faux) puis arme la surveillance sur le thread principal.
    func start() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Tronque (ou crée) : on repart à vide à chaque lancement de l'app.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 { close(fd) }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        self.handle = handle
        self.offset = 0
        self.buffer.removeAll()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopen()          // fichier supprimé/renommé → ré-armer
            } else {
                self.drain()
            }
        }
        src.setCancelHandler { [weak handle] in
            try? handle?.close()
        }
        self.source = src
        src.resume()
    }

    func stop() {
        source?.cancel()               // le cancelHandler ferme le handle
        source = nil
        handle = nil
    }

    // MARK: - Privé

    /// Le fichier a été supprimé/renommé (le fd pointe l'ancien inode) : on ré-arme
    /// sur le nouveau fichier. Léger debounce pour éviter une boucle après notre
    /// propre truncate.
    private func reopen() {
        guard !reopening else { return }
        reopening = true
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reopening = false
            self?.start()
        }
    }

    /// Lit les octets ajoutés depuis `offset`, découpe en lignes complètes et
    /// décode chaque `ChannelEvent`. La ligne partielle finale est conservée.
    private func drain() {
        guard let handle else { return }
        guard let end = try? handle.seekToEnd() else { return }
        if end < offset {              // troncature / rotation → on repart de zéro
            offset = 0
            buffer.removeAll()
        }
        guard end > offset else { return }
        do { try handle.seek(toOffset: offset) } catch { return }
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        offset = end
        guard !data.isEmpty else { return }
        buffer.append(data)

        let newline = UInt8(ascii: "\n")
        while let nl = buffer.firstIndex(of: newline) {
            let lineData = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])   // rebase → 0-based
            guard !lineData.isEmpty,
                  let event = try? JSONDecoder().decode(ChannelEvent.self, from: lineData)
            else { continue }
            onEvent(event)
        }
    }
}
