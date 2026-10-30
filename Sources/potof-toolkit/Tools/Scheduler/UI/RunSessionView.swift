import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Lecture incrémentale du .tty

/// Relit un `.tty` **depuis un décalage**. C'est ce qui permet de suivre un run en cours :
/// le runner (un autre process) ajoute au fichier, la vue ne relit que la suite.
///
/// Fichier absent ou plus court que `offset` ⇒ (vide, `offset` inchangé) : le `.tty` n'est
/// créé qu'au premier octet émis, et une vue ouverte juste après « Lancer maintenant »
/// arrive avant lui.
enum TTYFileReader {
    static func read(_ url: URL, from offset: UInt64) -> (data: Data, offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), offset) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return (Data(), offset) }
        let data = handle.readDataToEndOfFile()
        return (data, offset + UInt64(data.count))
    }
}

// MARK: - Reprise dans Claude Launcher

/// Pont vers Claude Launcher : `claude --resume <sessionID>` dans le dossier de la
/// planification. Le `sessionID` est celui que le runner a **imposé** à `claude`
/// (`--session-id`), donc la conversation est retrouvable sans rien deviner.
enum ScheduleResume {

    /// `<projectsRoot>/<dossier encodé>/<sessionID>.jsonl` — la conversation que `claude`
    /// a écrite. Sa présence est la seule preuve qu'il y a quelque chose à reprendre.
    static func transcriptURL(folderPath: String, sessionID: String) -> URL {
        PreviousSessionsStore.projectsRoot
            .appendingPathComponent(PreviousSessionsStore.projectDirName(forPath: folderPath),
                                    isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    static func canResume(_ run: RunRecord, folderPath: String) -> Bool {
        unavailableReason(run, folderPath: folderPath) == nil
    }

    /// Pourquoi le bouton est grisé (`nil` = reprise possible). Sert d'aide au survol.
    static func unavailableReason(_ run: RunRecord, folderPath: String) -> String? {
        if run.status == .running { return "Run en cours : la conversation n'est pas encore reprenable." }
        guard let sessionID = run.sessionID, !sessionID.isEmpty else {
            return "Aucune conversation enregistrée : ce run n'est pas allé jusqu'à claude."
        }
        let transcript = transcriptURL(folderPath: folderPath, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: transcript.path) else {
            return "Aucune conversation enregistrée : \(transcript.lastPathComponent) est introuvable."
        }
        return nil
    }

    /// Ouvre une session Claude Launcher en reprise puis bascule d'outil. `launch` active
    /// la session créée ; on la désigne au coordinateur, comme un clic de notification.
    static func resume(_ run: RunRecord, folderPath: String) {
        guard let sessionID = run.sessionID else { return }
        let store = SessionStore.shared
        store.launch(folder: URL(fileURLWithPath: folderPath, isDirectory: true), resume: sessionID)
        guard let id = store.activeID else { return }
        NotificationCenterCoordinator.shared.focusRequests.send(
            FocusRequest(sessionID: id, toolID: ClaudeLauncherView.toolID))
    }
}

// MARK: - Rejeu

/// Possède le `TerminalView` de rejeu et l'alimente depuis le `.tty`.
///
/// **`TerminalView` et non `LocalProcessTerminalView`** : aucun process ici, juste un
/// émulateur à qui l'on `feed` des octets. Lecture seule : `terminalDelegate` reste `nil`
/// (`send(source:data:)` ne transmet alors rien, la saisie est jetée) et la souris n'est
/// pas rapportée.
///
/// Grille **forcée à 120×40**, celle du PTY du runner : un autre format ferait réarranger
/// à l'émulateur un rendu pensé pour 120 colonnes, et le TUI de `claude` en sortirait
/// illisible. Si le panneau est plus petit, c'est le conteneur qui défile.
///
/// Suivi : `DispatchSource` vnode (`.write|.extend`) sur le fichier. Un run **terminé** est
/// lu d'une traite et rien n'est surveillé.
final class TTYReplay: ObservableObject {

    let terminalView: TerminalView
    /// Cadre qui contient exactement 120×40 cellules (scroller compris).
    let contentSize: NSSize

    private let url: URL
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var stopped = false

    /// Au-delà, on nourrit l'émulateur par tranches : un `.tty` de plusieurs Mo d'un coup
    /// bloquerait le thread principal sans rien afficher entre-temps.
    private static let sliceSize = 256 * 1024

    init(url: URL, follow: Bool) {
        self.url = url

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.allowMouseReporting = false
        view.terminalDelegate = nil
        view.getTerminal().resize(cols: Int(PTYProcess.columns), rows: Int(PTYProcess.rows))
        // ⚠️ `setFrameSize` recalcule la grille par `Int(largeur / cellule)` : à la valeur
        // exacte de `getOptimalFrameSize()`, un arrondi flottant peut donner 119 colonnes.
        // Une demi-cellule de marge ne coûte rien et ferme la porte.
        let optimal = view.getOptimalFrameSize()
        contentSize = NSSize(width: optimal.width + 0.5, height: optimal.height + 0.5)
        view.frame = NSRect(origin: .zero, size: contentSize)
        terminalView = view

        pump()
        if follow { watch() }
    }

    deinit { stop() }

    /// Relit la suite du fichier et la donne à l'émulateur. Thread principal.
    func pump() {
        let chunk = TTYFileReader.read(url, from: offset)
        guard !chunk.data.isEmpty else { return }
        offset = chunk.offset
        let bytes = [UInt8](chunk.data)
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.sliceSize, bytes.count)
            terminalView.feed(byteArray: bytes[start..<end])
            start = end
        }
    }

    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        source?.cancel()      // le cancelHandler ferme le descripteur
        source = nil
    }

    private func watch() {
        guard !stopped, source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Pas encore de `.tty` : le runner n'a rien émis. On réessaie, sans tourner
            // indéfiniment si la vue disparaît (`stop()` annule).
            let work = DispatchWorkItem { [weak self] in self?.pumpThenWatch() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in self?.pump() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func pumpThenWatch() {
        pump()
        watch()
    }
}

/// Place le terminal de rejeu dans un conteneur à taille fixe (celle de la grille).
private struct ReplayTerminal: NSViewRepresentable {
    let replay: TTYReplay

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: replay.contentSize))
        container.addSubview(replay.terminalView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = replay.terminalView
        if view.superview !== container { container.addSubview(view) }
        if view.frame.size != replay.contentSize {
            view.frame = NSRect(origin: .zero, size: replay.contentSize)
        }
    }
}

// MARK: - Vue « Session »

/// Onglet « Session » : le rendu CLI d'un run, en direct s'il tourne encore, et le bouton
/// de reprise dans Claude Launcher.
///
/// ⚠️ Poser `.id(run.id)` côté appelant : le `TTYReplay` (`@StateObject`) est lié à **un**
/// fichier, un autre run doit repartir d'un terminal vierge.
struct RunSessionView: View {

    let run: RunRecord
    let schedule: Schedule

    @StateObject private var replay: TTYReplay

    init(run: RunRecord, schedule: Schedule) {
        self.run = run
        self.schedule = schedule
        let url = SchedulePaths.ttyFile(runID: run.id)
        let follow = run.status == .running
        _replay = StateObject(wrappedValue: TTYReplay(url: url, follow: follow))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ReplayTerminal(replay: replay)
                    .frame(width: replay.contentSize.width, height: replay.contentSize.height)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        // La ligne `end` arrive après le dernier octet du flux : une relecture à la fin
        // ne coûte rien et garantit que la vue n'a rien raté.
        .onChange(of: run.status) { _ in replay.pump() }
    }

    private var resumeReason: String? {
        ScheduleResume.unavailableReason(run, folderPath: schedule.folderPath)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RunStatusPill(status: run.status, date: run.startedAt)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.message)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(Self.absolute(run.startedAt))
                    if let duration = run.duration {
                        Text("· \(Self.duration(duration))").monospacedDigit()
                    } else if run.status == .running {
                        Text("· en cours")
                    }
                    Text("· \(run.trigger)")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                ScheduleResume.resume(run, folderPath: schedule.folderPath)
            } label: {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .disabled(resumeReason != nil)
            .help(resumeReason ?? "Reprendre dans Claude Launcher : rouvre la conversation de ce "
                  + "run (claude --resume) dans le dossier de la planification.")
            .accessibilityLabel("Reprendre dans Claude Launcher")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMM yyyy 'à' HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1f s", seconds)
            : String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }
}
