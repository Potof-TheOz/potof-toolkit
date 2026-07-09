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

        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = self
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
