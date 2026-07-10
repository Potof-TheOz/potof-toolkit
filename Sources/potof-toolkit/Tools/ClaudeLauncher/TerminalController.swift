import AppKit
import SwiftTerm

/// Possède les vues terminal AppKit (une par session), lance et termine les
/// process `claude`, et relaie les événements de cycle de vie du process.
///
/// ⚠️ Invariant : les `LocalProcessTerminalView` sont **conservées vivantes ici**
/// (jamais recréées lors d'un changement de session) afin de préserver le
/// scrollback et surtout le process enfant. `TerminalHostView` ne fait que placer
/// la bonne vue dans un conteneur.
///
/// Toutes les mutations d'état (dictionnaires) se font sur le **thread principal** :
/// les callbacks du delegate SwiftTerm y sont remarshalés.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {

    /// Instance unique : l'app n'héberge qu'un `ClaudeLauncher`. Permet à
    /// `AppDelegate` d'interroger l'état des sessions au moment de quitter.
    static let shared = TerminalController()

    /// Vue terminal par session.
    private var views: [UUID: LocalProcessTerminalView] = [:]
    /// id de session par vue (retrouver la session dans les callbacks delegate).
    private var idByView: [ObjectIdentifier: UUID] = [:]
    /// Serveur d'intégration IDE par session (aperçu des diffs Claude). Cf.
    /// `docs/IDE_BRIDGE.md`. Cycle de vie collé à celui du process.
    private var ideServers: [UUID: IDEServer] = [:]

    /// Relais vers le store (appelés sur le thread principal).
    var onTitleChange: ((UUID, String) -> Void)?
    var onProcessExit: ((UUID, Int32?) -> Void)?
    /// Intégration IDE : Claude demande un aperçu de diff (openDiff) dans une session.
    /// La complétion renvoie le verdict au CLI. Ferme d'onglet(s) = annulation Claude.
    var onOpenDiff: ((UUID, IDEDiffRequest, @escaping (IDEDiffVerdict) -> Void) -> Void)?
    var onCloseTab: ((UUID, String) -> Void)?
    var onCloseAllTabs: ((UUID) -> Void)?

    /// Vue terminal d'une session (nil si aucune / déjà libérée).
    func view(for id: UUID) -> LocalProcessTerminalView? { views[id] }

    /// Écrit des octets bruts dans le PTY d'une session (ex. répondre `Entrée` à un
    /// prompt de permission). No-op si la session n'existe pas.
    func sendKeys(id: UUID, _ text: String) {
        views[id]?.send(txt: text)
    }

    /// Texte **rendu** de l'écran actif du terminal (buffer alterné de la TUI Claude).
    /// Sert à détecter un prompt de permission avant d'y répondre. Vide si absent.
    func screenText(id: UUID) -> String {
        guard let term = views[id] else { return "" }
        return String(data: term.getTerminal().getBufferAsData(kind: .active), encoding: .utf8) ?? ""
    }

    /// Nombre de sessions dont le process (shell + éventuel `claude`) tourne encore.
    /// Utilisé par la confirmation de fermeture de l'app.
    var runningProcessCount: Int {
        views.values.filter { $0.process?.running == true }.count
    }

    // MARK: - Cycle de vie

    /// Lance une nouvelle session `claude` dans `folder`. Idempotent par `id`.
    /// `resume` (id de conversation Claude) → reprise via `claude --resume <id>`.
    @discardableResult
    func start(id: UUID, folder: URL, resume: String? = nil) -> LocalProcessTerminalView {
        if let existing = views[id] { return existing }

        let term = EmbeddedTerminalView(frame: .zero)
        term.processDelegate = self
        // Coupe le *mouse reporting* vers la TUI : sinon un clic/survol de la souris sur
        // le terminal (typiquement quand la fenêtre passe au premier plan via une notif,
        // curseur au-dessus d'un bouton « Yes »/« No ») sélectionne le prompt de
        // permission à l'insu de l'utilisateur. `allowMouseReporting=false` couvre
        // clic/drag ; `EmbeddedTerminalView` couvre en plus le *survol* (mouseMoved, que
        // SwiftTerm ne garde PAS derrière ce drapeau). Résultat : la souris fait de la
        // sélection de texte native ; on navigue les prompts au clavier.
        term.allowMouseReporting = false
        views[id] = term
        idByView[ObjectIdentifier(term)] = id

        // Shell de **login + interactif** (`-l -i`) sur un PTY → sourcing complet
        // des rc (`.zprofile`/`.zshrc`, Homebrew, nvm…), donc `claude` est résolu
        // comme dans iTerm2. Le `-i` explicite couvre les shells (ex. bash) qui ne
        // sourcent `.*rc` qu'en mode interactif.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.append("POTOF_SESSION_ID=\(id.uuidString)")   // ancrage notif (Phase 4)

        // Intégration IDE : un serveur MCP par session. On l'ouvre AVANT le spawn
        // pour injecter `CLAUDE_CODE_SSE_PORT`/`ENABLE_IDE_INTEGRATION` dans l'env →
        // `claude` route alors ses éditions vers l'app via `openDiff` (aperçu +
        // accepter/refuser) au lieu d'écrire directement. L'env prime sur le scan
        // des locks, donc gagne sur un WebStorm ouvert. Voir docs/IDE_BRIDGE.md.
        let ide = IDEServer(sessionID: id, workspace: folder)
        if ide.isAvailable {
            ide.onOpenDiff = { [weak self] req, done in self?.onOpenDiff?(id, req, done) }
            ide.onCloseTab = { [weak self] tab in self?.onCloseTab?(id, tab) }
            ide.onCloseAllTabs = { [weak self] in self?.onCloseAllTabs?(id) }
            ide.start()
            env.append(contentsOf: ide.environment)
            ideServers[id] = ide
        }

        term.startProcess(
            executable: Self.userShell(),
            args: ["-l", "-i"],
            environment: env,
            currentDirectory: folder.path
        )

        // On laisse le shell finir de s'initialiser avant d'« écrire » la commande,
        // comme le faisait iTerm2 (`write text`). Le PTY bufferise de toute façon.
        let cmd = Self.launchCommand(folder: folder, resume: resume)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak term] in
            term?.send(txt: cmd)
        }
        return term
    }

    /// Termine le process d'une session (fermeture **volontaire**) et libère sa vue.
    /// On coupe le delegate d'abord pour ne pas déclencher `onProcessExit`.
    func terminate(id: UUID) {
        ideServers[id]?.stop()          // ferme le serveur IDE + supprime son lock
        ideServers[id] = nil
        guard let term = views[id] else { return }
        term.processDelegate = nil
        term.terminate()
        idByView[ObjectIdentifier(term)] = nil
        views[id] = nil
    }

    func terminateAll() {
        for id in Array(views.keys) { terminate(id: id) }
    }

    // MARK: - Commande / shell

    /// `cd '<dossier>' && claude [--resume '<id>']` — échappement shell (apostrophe
    /// → `'\''`), suivi d'un retour chariot (valide comme une frappe « Entrée »).
    /// `resume` non nil ⇒ reprise d'une session précédente par son id de conversation.
    private static func launchCommand(folder: URL, resume: String? = nil) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        var cmd = "cd '\(esc(folder.path))' && claude"
        if let resume, !resume.isEmpty { cmd += " --resume '\(esc(resume))'" }
        return cmd + "\r"
    }

    private static func userShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let oid = ObjectIdentifier(source)
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.idByView[oid], !title.isEmpty else { return }
            self.onTitleChange?(id, title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let term = source as? LocalProcessTerminalView else { return }
        let oid = ObjectIdentifier(term)
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.idByView[oid] else { return }
            self.onProcessExit?(id, exitCode)
        }
    }
}

/// Terminal embarqué. Jette les **reports souris SGR** (`ESC [ < … M/m`) avant qu'ils
/// n'atteignent le PTY : SwiftTerm envoie les événements `mouseMoved` (encodés comme un
/// « release ») dès que la TUI active le suivi souris, **sans** les garder derrière
/// `allowMouseReporting` (et `mouseMoved` n'est pas `open`, donc non surchargeable).
/// Un simple survol d'un bouton « Yes »/« No » suffisait alors à valider/refuser un
/// prompt de permission. `send(source:data:)` est le point de passage unique de tout
/// ce qui part vers le process : on y filtre les reports souris. La sélection de texte
/// native (clic/drag) reste intacte grâce à `allowMouseReporting=false` (les handlers
/// clic/drag basculent en sélection locale au lieu de reporter).
final class EmbeddedTerminalView: LocalProcessTerminalView {
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if Self.isFilterableMouseReport(data) { return }
        super.send(source: source, data: data)
    }

    // MARK: - Molette → reports SGR

    /// Moniteur d'événements molette. SwiftTerm-mac ne forwarde **jamais** la molette à la
    /// TUI : son `scrollWheel` ne scrolle que le scrollback **local** (buffer normal
    /// uniquement), inutile quand Claude possède l'écran. On ne peut pas non plus surcharger
    /// `scrollWheel` (déclaré `public`, pas `open`, hors de notre module) → on intercepte via
    /// un moniteur local. Actif uniquement tant que la vue est dans une fenêtre (donc la
    /// session **affichée**), ce qui évite qu'une session en arrière-plan capte la molette.
    private var scrollMonitor: Any?

    /// Moniteur clavier. Même contrainte que la molette : `keyDown` est `public`
    /// (pas `open`) hors de notre module → pas surchargeable. Sert à traduire
    /// Shift/Option+Entrée en saut de ligne pour le prompt Claude (cf. `handleKeyDown`).
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        } else {
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handleScroll(event) ?? event
                }
            }
            if keyMonitor == nil {
                // NB : on ne peut PAS écrire `self?.handleKeyDown(event) ?? event` — le
                // `nil` que `handleKeyDown` renvoie pour **consommer** l'événement serait
                // retransformé en `event` par le `??`, laissant le `keyDown` natif de
                // SwiftTerm s'exécuter (et valider le prompt). On ne retombe sur `event`
                // que si `self` a disparu.
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handleKeyDown(event)
                }
            }
        }
    }

    deinit {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Saut de ligne dans le prompt Claude

    /// La TUI de Claude Code valide le prompt sur **Entrée simple** ; pour insérer un
    /// saut de ligne il faut **Meta+Entrée** (`ESC` + `CR`) — exactement ce que la
    /// config `/terminal-setup` d'iTerm2 mappait sur Shift+Entrée. Option+Entrée passe
    /// déjà par le chemin natif `optionAsMetaKey` de SwiftTerm (→ `ESC CR`), mais
    /// Shift+Entrée n'a aucun équivalent natif : on le traduit ici en `ESC CR`.
    ///
    /// Seul garde : **ce** terminal (ou une de ses sous-vues) doit avoir le focus, pour
    /// ne pas détourner une frappe destinée ailleurs (ex. champ de recherche de la
    /// sidebar). Pas de gate « suivi souris » : Claude ne l'active pas forcément pendant
    /// la saisie du prompt (c'était ça qui neutralisait Shift+Entrée). Consommer
    /// l'événement évite le double envoi (submit natif ou report kitty).
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = window, event.window === window else { return event }
        let focused = (window.firstResponder as? NSView).map {
            $0 === self || $0.isDescendant(of: self)
        } ?? false
        guard focused else { return event }
        let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return / Enter (pavé num.)
        let mods = event.modifierFlags
        guard isReturn, mods.contains(.shift) || mods.contains(.option) else { return event }
        send(txt: "\u{1b}\r")   // Meta+Entrée → saut de ligne dans le prompt Claude
        return nil              // consommé : pas de submit natif (Shift) ni de double envoi (Option)
    }

    /// Traduit la molette en reports « bouton molette » SGR (64 = haut, 65 = bas) pour que
    /// Claude scrolle sa propre vue. Ne traite que si le curseur est **au-dessus de ce
    /// terminal** et que la TUI a activé le suivi souris ; sinon renvoie l'événement tel quel
    /// (scrollback local natif pour un shell nu, scroll normal ailleurs — ex. sidebar). Ces
    /// reports (bouton ≥ 64) ne déclenchent jamais la sélection Yes/No qui a motivé
    /// `allowMouseReporting=false` (cf. `isFilterableMouseReport`, qui les laisse passer).
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window = window, event.window === window else { return event }
        let term = getTerminal()
        guard event.deltaY != 0, term.mouseMode != .off else { return event }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return event }

        let mods = event.modifierFlags
        let button = event.deltaY > 0 ? 4 : 5   // 4 = molette haut, 5 = molette bas
        let cb = term.encodeButton(button: button, release: false,
                                   shift: mods.contains(.shift),
                                   meta: mods.contains(.option),
                                   control: mods.contains(.control))
        // Position grille sous le curseur (Claude est plein cadre → importe peu, mais on la
        // calcule pour rester conforme au protocole).
        let cols = max(term.cols, 1), rows = max(term.rows, 1)
        let col = min(max(Int(p.x / (bounds.width / CGFloat(cols))), 0), cols - 1)
        let row = min(max(Int((bounds.height - p.y) / (bounds.height / CGFloat(rows))), 0), rows - 1)
        // Un report par « cran », borné pour ne pas noyer la TUI (le trackpad émet beaucoup
        // de petits deltas avec inertie).
        let steps = min(max(Int(abs(event.deltaY).rounded()), 1), 4)
        for _ in 0..<steps {
            term.sendEvent(buttonFlags: cb, x: col, y: row)
        }
        return nil   // consommé : empêche le scrollback local natif de SwiftTerm de scroller
    }

    /// Vrai si `data` est un report souris SGR à **jeter** (`ESC [ < b ; … M/m` avec
    /// `b < 64`) : clic, drag, survol. On **laisse passer** les reports molette
    /// (`b ≥ 64`, émis par `scrollWheel`) pour préserver le scroll de la TUI.
    private static func isFilterableMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 4 else { return false }
        var idx = data.startIndex
        guard data[idx] == 0x1b else { return false }          // ESC
        idx = data.index(after: idx)
        guard data[idx] == 0x5b else { return false }          // [
        idx = data.index(after: idx)
        guard data[idx] == 0x3c else { return false }          // <
        idx = data.index(after: idx)
        let last = data[data.index(before: data.endIndex)]
        guard last == 0x4d || last == 0x6d else { return false }   // 'M' (press) / 'm' (release)
        // Numéro de bouton (chiffres jusqu'au premier ';').
        var button = 0, sawDigit = false
        while idx < data.endIndex, data[idx] >= 0x30, data[idx] <= 0x39 {
            button = button * 10 + Int(data[idx] - 0x30)
            sawDigit = true
            idx = data.index(after: idx)
        }
        guard sawDigit else { return false }
        return button < 64   // 0-2 = clic (+32 = motion) → jetés ; 64/65 = molette → gardés
    }
}
