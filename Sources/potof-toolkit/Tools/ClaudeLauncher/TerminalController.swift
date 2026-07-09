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

    /// Relais vers le store (appelés sur le thread principal).
    var onTitleChange: ((UUID, String) -> Void)?
    var onProcessExit: ((UUID, Int32?) -> Void)?

    /// Vue terminal d'une session (nil si aucune / déjà libérée).
    func view(for id: UUID) -> LocalProcessTerminalView? { views[id] }

    /// Nombre de sessions dont le process (shell + éventuel `claude`) tourne encore.
    /// Utilisé par la confirmation de fermeture de l'app.
    var runningProcessCount: Int {
        views.values.filter { $0.process?.running == true }.count
    }

    // MARK: - Cycle de vie

    /// Lance une nouvelle session `claude` dans `folder`. Idempotent par `id`.
    @discardableResult
    func start(id: UUID, folder: URL) -> LocalProcessTerminalView {
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

        term.startProcess(
            executable: Self.userShell(),
            args: ["-l", "-i"],
            environment: env,
            currentDirectory: folder.path
        )

        // On laisse le shell finir de s'initialiser avant d'« écrire » la commande,
        // comme le faisait iTerm2 (`write text`). Le PTY bufferise de toute façon.
        let cmd = Self.launchCommand(folder: folder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak term] in
            term?.send(txt: cmd)
        }
        return term
    }

    /// Termine le process d'une session (fermeture **volontaire**) et libère sa vue.
    /// On coupe le delegate d'abord pour ne pas déclencher `onProcessExit`.
    func terminate(id: UUID) {
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

    /// `cd '<dossier>' && claude` — échappement shell (apostrophe → `'\''`), suivi
    /// d'un retour chariot (valide comme une frappe « Entrée »).
    private static func launchCommand(folder: URL) -> String {
        let escaped = folder.path.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(escaped)' && claude\r"
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
        if Self.isSGRMouseReport(data) { return }
        super.send(source: source, data: data)
    }

    /// Vrai si `data` est un report souris SGR : `ESC [ < … (M|m)`.
    private static func isSGRMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count >= 4 else { return false }
        var it = data.makeIterator()
        guard it.next() == 0x1b, it.next() == 0x5b, it.next() == 0x3c else { return false }
        let last = data[data.index(before: data.endIndex)]
        return last == 0x4d || last == 0x6d   // 'M' (press) ou 'm' (release)
    }
}
