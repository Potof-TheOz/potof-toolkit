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
///
/// `limit` borne la lecture : un `.tty` de plusieurs dizaines de Mo n'est jamais chargé
/// d'un bloc en mémoire, l'appelant le relit tranche par tranche.
enum TTYFileReader {
    static func read(_ url: URL, from offset: UInt64,
                     limit: Int = .max) -> (data: Data, offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), offset) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return (Data(), offset) }
        let data = ((try? handle.read(upToCount: limit)) ?? nil) ?? Data()
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
    ///
    /// Cherchée par son **sessionID** (unique) dans tous les dossiers de projets, et non
    /// recalculée depuis le chemin : `projectDirName` ne transforme que `/`, `.` et `_`,
    /// alors qu'un dossier avec un espace, un lien ou un `/` final donne un autre nom côté
    /// `claude`. Le nom calculé n'est qu'un premier essai, pour éviter le parcours.
    static func transcriptURL(folderPath: String, sessionID: String) -> URL? {
        let fm = FileManager.default
        let root = PreviousSessionsStore.projectsRoot
        let name = "\(sessionID).jsonl"
        let guess = root
            .appendingPathComponent(PreviousSessionsStore.projectDirName(forPath: folderPath),
                                    isDirectory: true)
            .appendingPathComponent(name)
        if fm.fileExists(atPath: guess.path) { return guess }
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return projects.lazy
            .map { $0.appendingPathComponent(name) }
            .first { fm.fileExists(atPath: $0.path) }
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
        guard transcriptURL(folderPath: folderPath, sessionID: sessionID) != nil else {
            return "Aucune conversation enregistrée : \(sessionID).jsonl est introuvable."
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
/// **Toujours 120 colonnes**, celles du PTY du runner : un autre nombre ferait réarranger à
/// l'émulateur un rendu pensé pour 120 colonnes, et le TUI de `claude` en sortirait
/// illisible. Pour occuper toute la largeur du panneau, on joue sur la **police**, et la
/// hauteur du panneau donne le **nombre de lignes** (en changer ne re-découpe rien : les
/// lignes en trop passent dans l'historique). Voir `fit(to:)`.
///
/// Suivi : `DispatchSource` vnode (`.write|.extend`) sur le fichier. Un run **terminé** est
/// relu sans rien surveiller. Dans les deux cas la lecture se fait **par tranches**, avec
/// un retour au runloop entre deux tranches : la fenêtre reste réactive pendant qu'une
/// session de plusieurs dizaines de Mo est rejouée.
final class TTYReplay: ObservableObject {

    /// Remplacé, et le fichier rejoué depuis le début, quand la police change.
    @Published private(set) var terminalView: TerminalView
    /// Le run est fini et n'a jamais écrit de `.tty` (échec avant le préscript et `claude`).
    @Published private(set) var noSession = false

    private let url: URL
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var following: Bool
    private var draining = false
    private var stopped = false

    /// Le rejeu n'est lancé qu'au premier `fit(to:)` : la police dépend de la largeur du
    /// panneau, et rejouer d'abord à la taille par défaut ferait tout relire deux fois.
    private var started = false
    private var fontSize: CGFloat
    private var panelSize: NSSize = .zero
    private var pendingRebuild: DispatchWorkItem?

    /// Taille d'une tranche donnée à l'émulateur avant de rendre la main au runloop.
    private static let sliceSize = 256 * 1024
    /// Pause entre deux tranches : un `async` nu pourrait être servi à la suite, sans que
    /// le runloop traite la saisie ni le dessin ; une échéance le force.
    private static let sliceGap: TimeInterval = 0.002
    static let fontSizeRange: ClosedRange<CGFloat> = 8...28
    /// Pendant un redimensionnement à la souris, on ne reconstruit qu'une fois la taille posée.
    private static let rebuildDelay: TimeInterval = 0.2
    /// Police par défaut de SwiftTerm (son `FontSet` est interne) : on n'en change que la taille.
    private static let defaultFont = TerminalView(frame: .zero).font
    /// Historique du terminal de rejeu. SwiftTerm en garde 500 lignes par défaut : sur une
    /// longue session, le début (préscript, premiers outils) sortait de la vue alors qu'il
    /// est dans le `.tty`.
    static let scrollbackLines = 10_000

    init(url: URL, follow: Bool) {
        self.url = url
        self.following = follow
        let view = Self.makeView(fontSize: nil)
        fontSize = view.font.pointSize
        terminalView = view
        if follow { watch() } else { noSession = !FileManager.default.fileExists(atPath: url.path) }
    }

    deinit { stop() }

    /// Un terminal neuf de 120×40 à la police demandée (`nil` = police par défaut de
    /// SwiftTerm). Jamais de changement de police sur un terminal déjà rempli : SwiftTerm
    /// recalculerait les colonnes et re-découperait le contenu.
    private static func makeView(fontSize: CGFloat?) -> TerminalView {
        let font = fontSize.map { size in
            NSFont(descriptor: defaultFont.fontDescriptor, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), font: font)
        view.allowMouseReporting = false
        view.terminalDelegate = nil
        view.getTerminal().changeScrollback(scrollbackLines)
        view.getTerminal().resize(cols: Int(PTYProcess.columns), rows: Int(PTYProcess.rows))
        // ⚠️ `setFrameSize` recalcule la grille par `Int(largeur / cellule)` : à la valeur
        // exacte de `getOptimalFrameSize()`, un arrondi flottant peut donner 119 colonnes.
        // Une demi-cellule de marge ne coûte rien et ferme la porte.
        let optimal = view.getOptimalFrameSize()
        view.frame = NSRect(x: 0, y: 0, width: optimal.width + 0.5, height: optimal.height + 0.5)
        return view
    }

    /// Appelée par le conteneur à chaque changement de taille du panneau. La hauteur
    /// s'applique tout de suite (nombre de lignes) ; la largeur choisit la police, et un
    /// changement de police reconstruit le terminal, après `rebuildDelay`.
    func fit(to size: NSSize) {
        guard size.width > 0, size.height > 0, !stopped else { return }
        panelSize = size
        let target = targetFontSize(forWidth: size.width)
        if !started {
            started = true
            // Hors de la passe de mise en page en cours : `rebuild` publie `terminalView`.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if target != self.fontSize { self.rebuild(fontSize: target) } else { self.applyHeight(); self.pump() }
            }
            return
        }
        applyHeight()
        pendingRebuild?.cancel()
        guard target != fontSize else { return }
        let work = DispatchWorkItem { [weak self] in self?.rebuild(fontSize: target) }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rebuildDelay, execute: work)
    }

    /// Police qui fait tenir 120 colonnes dans `width`, par pas d'un demi-point.
    private func targetFontSize(forWidth width: CGFloat) -> CGFloat {
        let raw = fontSize * width / terminalView.frame.width
        let stepped = (raw * 2).rounded(.down) / 2
        return min(max(stepped, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    /// Les colonnes restent celles du cadre actuel (120) ; seule la hauteur, donc le nombre
    /// de lignes, suit le panneau.
    private func applyHeight() {
        let size = NSSize(width: terminalView.frame.width, height: panelSize.height)
        if terminalView.frame.size != size { terminalView.frame = NSRect(origin: .zero, size: size) }
    }

    /// Terminal neuf à la nouvelle police, rejoué depuis le début du fichier. Une relecture
    /// déjà en cours continue sur le nouveau terminal, depuis le nouvel `offset`.
    private func rebuild(fontSize target: CGFloat) {
        guard !stopped else { return }
        var size = target
        var view = Self.makeView(fontSize: size)
        // La règle de trois ignore la barre de défilement, de largeur fixe : on redescend
        // d'un cran tant que les 120 colonnes débordent.
        while view.frame.width > panelSize.width, size > Self.fontSizeRange.lowerBound {
            size -= 0.5
            view = Self.makeView(fontSize: size)
        }
        fontSize = size
        terminalView = view
        applyHeight()
        offset = 0
        if !draining { pump() }
    }

    /// Relit la suite du fichier et la donne à l'émulateur, une tranche à la fois.
    /// Thread principal. Sans effet si une relecture est déjà en cours : elle ira
    /// jusqu'à la fin du fichier, donc jusqu'aux octets que ce nouvel appel annonçait.
    func pump() {
        guard started, !draining, !stopped else { return }
        feedNextSlice()
    }

    private func feedNextSlice() {
        let chunk = TTYFileReader.read(url, from: offset, limit: Self.sliceSize)
        guard !chunk.data.isEmpty, !stopped else { draining = false; return }
        offset = chunk.offset
        draining = true
        terminalView.feed(byteArray: [UInt8](chunk.data)[...])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sliceGap) { [weak self] in
            self?.feedNextSlice()
        }
    }

    /// Le run n'est plus « en cours » : dernière relecture, plus de surveillance ni de
    /// réessai. Sans `.tty` à ce stade, il n'y en aura jamais.
    func runEnded() {
        following = false
        retry?.cancel()
        retry = nil
        pump()
        source?.cancel()
        source = nil
        noSession = !FileManager.default.fileExists(atPath: url.path)
    }

    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        source?.cancel()      // le cancelHandler ferme le descripteur
        source = nil
    }

    private func watch() {
        guard !stopped, following, source == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Pas encore de `.tty` : le runner n'a rien émis. On réessaie tant que le run
            // est en cours (`runEnded()` et `stop()` annulent).
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

/// Conteneur du terminal de rejeu : il remplit le panneau et lui transmet sa taille
/// (`TTYReplay.fit(to:)`), qui choisit la police et le nombre de lignes. Pas de
/// `ScrollView` autour : elle donnait une 2ᵉ barre verticale à côté de celle de l'historique
/// du terminal (vu en recette). Pas de mise à l'échelle non plus : SwiftTerm dessine sur un
/// calque (`wantsLayer`), qu'un agrandissement rendrait flou.
private final class ReplayContainer: NSView {

    private let replay: TTYReplay

    init(replay: TTYReplay) {
        self.replay = replay
        super.init(frame: .zero)
        attach(replay.terminalView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    override var isFlipped: Bool { true }

    /// Place le terminal courant en haut à gauche, à la place de l'ancien s'il a été reconstruit.
    func attach(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(terminal)
        terminal.setFrameOrigin(.zero)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        replay.fit(to: newSize)
    }
}

/// Place le terminal de rejeu dans le `ReplayContainer`.
private struct ReplayTerminal: NSViewRepresentable {
    @ObservedObject var replay: TTYReplay

    func makeNSView(context: Context) -> ReplayContainer {
        ReplayContainer(replay: replay)
    }

    func updateNSView(_ container: ReplayContainer, context: Context) {
        container.attach(replay.terminalView)
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
            if replay.noSession {
                Text("Aucune session enregistrée pour ce run.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                ReplayTerminal(replay: replay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        // La ligne `end` arrive après le dernier octet du flux : une relecture à la fin
        // ne coûte rien et garantit que la vue n'a rien raté.
        .onChange(of: run.status) { status in
            if status == .running { replay.pump() } else { replay.runEnded() }
        }
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
