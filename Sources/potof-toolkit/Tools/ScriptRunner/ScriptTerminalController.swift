import AppKit
import SwiftTerm

/// Possède les vues terminal des runs de scripts (une `LocalProcessTerminalView`
/// **nue** par run — pas d'`EmbeddedTerminalView`, dont les filtres souris/clavier
/// sont spécifiques à la TUI Claude). Pendant simplifié de `TerminalController` :
/// pas de pont IDE, pas de `POTOF_SESSION_ID`.
///
/// ⚠️ Invariants :
/// - Les vues sont **conservées vivantes, y compris après la mort du process**
///   (le scrollback d'un script terminé reste lisible) ; seule `release(id:)`
///   — fermeture manuelle du run — les libère.
/// - `terminate()` de SwiftTerm **annule le monitor d'exit** (plus aucun callback
///   `processTerminated` ensuite) : il ne sert qu'à la libération, JAMAIS à
///   l'escalade de kill (→ `hardKill`).
/// - Toutes les mutations d'état se font sur le **thread principal** (callbacks
///   du delegate SwiftTerm remarshalés).
final class ScriptTerminalController: NSObject, LocalProcessTerminalViewDelegate {

    /// Instance unique app-level : les runs doivent survivre au changement d'outil
    /// (`RootView` détruit les vues d'outil) et être comptés au quit (`AppDelegate`).
    static let shared = ScriptTerminalController()

    /// Vue terminal par run. Une entrée peut pointer un process **mort** (script
    /// terminé, scrollback conservé) : ne présume jamais `running` d'après la
    /// présence dans ce dictionnaire.
    private var views: [UUID: LocalProcessTerminalView] = [:]
    /// id de run par vue (retrouver le run dans les callbacks delegate).
    private var idByView: [ObjectIdentifier: UUID] = [:]
    /// Écriture différée (~0,35 s) de la commande, par run — conservée pour
    /// pouvoir l'**annuler** si le run est arrêté/fermé avant qu'elle ne parte
    /// (sinon un Stop dans cette fenêtre laisserait quand même démarrer le script).
    private var pendingSends: [UUID: DispatchWorkItem] = [:]

    /// Fin du process d'un run (appelé sur le thread principal). Le second
    /// paramètre est le **statut waitpid brut** livré par SwiftTerm → à décoder
    /// via `ScriptRun.decodeWaitStatus`.
    var onProcessExit: ((UUID, Int32?) -> Void)?

    /// Vue terminal d'un run (nil si inconnue / déjà libérée).
    func view(for id: UUID) -> LocalProcessTerminalView? { views[id] }

    /// Nombre de runs dont le process (shell ou script) tourne encore.
    /// Utilisé par la confirmation de fermeture de l'app.
    var runningProcessCount: Int {
        views.values.filter { $0.process?.running == true }.count
    }

    /// Le process du run est-il encore vivant ?
    func isRunning(id: UUID) -> Bool {
        views[id]?.process?.running == true
    }

    // MARK: - Cycle de vie

    /// Lance un run : spawn `$SHELL -l -i` (login + interactif → PATH complet :
    /// nvm/corepack sourcés par les rc) dans `packageDir`, puis écrit après ~0,35 s
    /// `cd '<packageDir>' && <command>; exit\r` — `command` est le fragment
    /// `<mgr> run '<script>'` déjà échappé (cf. `PackageManager.runCommand`).
    /// Le `; exit` fait mourir le shell à la fin du script → `processTerminated`
    /// = signal de fin + statut waitpid. Idempotent par `id`.
    @discardableResult
    func start(id: UUID, packageDir: URL, command: String) -> LocalProcessTerminalView {
        if let existing = views[id] { return existing }

        let term = LocalProcessTerminalView(frame: .zero)
        term.processDelegate = self
        views[id] = term
        idByView[ObjectIdentifier(term)] = id

        // Shell de **login + interactif** (`-l -i`) sur un PTY → sourcing complet
        // des rc (`.zprofile`/`.zshrc`, Homebrew, nvm…), donc npm/pnpm/yarn/bun
        // sont résolus comme dans iTerm2 (pattern éprouvé du Claude Launcher).
        // Env SwiftTerm standard uniquement : pas de POTOF_SESSION_ID (réservé
        // aux notifications des sessions Claude), pas de serveur IDE.
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(
            executable: Self.userShell(),
            args: ["-l", "-i"],
            environment: env,
            currentDirectory: packageDir.path
        )

        // Échec de `forkpty` (fork storm / fd épuisés) : `startProcess` rend la
        // main sans démarrer de process ni de monitor → aucun `processTerminated`
        // ne viendra. On signale l'échec nous-mêmes (async : le store doit avoir
        // fini d'enregistrer le run) → badge « Terminé » plutôt qu'un run fantôme.
        guard term.process?.running == true else {
            DispatchQueue.main.async { [weak self] in self?.onProcessExit?(id, nil) }
            return term
        }

        // On laisse le shell finir de s'initialiser avant d'« écrire » la commande
        // (même délai que le Claude Launcher ; le PTY bufferise de toute façon).
        // Work item conservé pour pouvoir l'annuler (Stop/kill avant l'envoi).
        let cmd = Self.scriptCommand(packageDir: packageDir, command: command)
        let work = DispatchWorkItem { [weak self, weak term] in
            term?.send(txt: cmd)
            self?.pendingSends[id] = nil
        }
        pendingSends[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        return term
    }

    /// Annule l'écriture différée de la commande si elle n'est pas encore partie
    /// (no-op sinon). Appelé dès qu'on arrête/kill/libère un run.
    private func cancelPendingSend(id: UUID) {
        pendingSends[id]?.cancel()
        pendingSends[id] = nil
    }

    // MARK: - Arrêt propre (séquence pilotée par ScriptRunStore)

    /// Étape (a) : Ctrl-C (0x03) dans le PTY → la line discipline (ISIG) délivre
    /// SIGINT au **groupe de premier plan** (le script ET ses enfants vite/esbuild).
    func sendInterrupt(id: UUID) {
        // Si la commande n'a pas encore été écrite (Stop dans les ~0,35 s après
        // le lancement), on l'annule : inutile — et dangereux — de démarrer le
        // script pour le tuer aussitôt.
        cancelPendingSend(id: id)
        // `send` est déjà un no-op silencieux quand le process est mort ; le
        // garde explicite documente que l'étape ne s'applique qu'à un run vivant.
        guard isRunning(id: id) else { return }
        views[id]?.send(txt: "\u{03}")
    }

    /// Étape (b) : écrit `exit\r`. À n'appeler que si `shellAtPrompt(id:)` est vrai
    /// (sinon on écrirait « exit » dans le stdin d'un script en shutdown gracieux).
    func sendExit(id: UUID) {
        guard isRunning(id: id) else { return }
        views[id]?.send(txt: "exit\r")
    }

    /// Vrai si le groupe de premier plan du PTY est le shell lui-même
    /// (`tcgetpgrp(childfd) == shellPid`) : le shell est revenu au prompt — zsh
    /// interactif **jette** le `; exit` de la ligne après un Ctrl-C.
    func shellAtPrompt(id: UUID) -> Bool {
        guard let process = views[id]?.process, process.running else { return false }
        let fd = process.childfd
        guard fd >= 0 else { return false }   // -1 dès l'EOF du PTY ou la libération
        return tcgetpgrp(fd) == process.shellPid
    }

    /// Étape (c) : SIGKILL au job entier (`kill(-tcgetpgrp(childfd), SIGKILL)`)
    /// puis au shell (`kill(shellPid, SIGKILL)` — groupe distinct sous job control).
    /// Lire `childfd` AVANT toute libération (il passe à -1). Surtout PAS
    /// `terminate()` ici : le monitor ne livrerait alors jamais l'exit (badge figé).
    func hardKill(id: UUID) {
        cancelPendingSend(id: id)   // commande pas encore écrite → ne pas la lancer
        guard let process = views[id]?.process, process.running else { return }
        // Le fd d'abord : `terminate()`/EOF le passent à -1 et on perdrait le
        // groupe de premier plan à tuer.
        let fd = process.childfd
        if fd >= 0 {
            let fg = tcgetpgrp(fd)
            if fg > 0 { kill(-fg, SIGKILL) }   // le job entier (script + enfants)
        }
        if process.shellPid > 0 { kill(process.shellPid, SIGKILL) }
        // Le DispatchSourceProcess reste armé → `processTerminated` arrive avec
        // le statut brut (signal 9), décodé plus haut en `.killed(signal:)`.
    }

    /// Libère la vue d'un run : coupe le delegate, retire la vue. Fermeture
    /// **manuelle**.
    ///
    /// ⚠️ On n'appelle `terminate()` que si le process est **encore vivant** :
    /// `LocalProcess.terminate()` fait `kill(shellPid, SIGTERM)`, or `shellPid`
    /// n'est jamais remis à zéro après le `waitpid` de `processTerminated` (le
    /// PID est alors déjà réapé). Comme un run terminé peut rester ouvert
    /// longtemps (feature : scrollback lisible), le PID a pu être **recyclé** par
    /// l'OS → SIGTERM tuerait un process innocent. Pour un process mort, on se
    /// contente de retirer la vue : son `deinit` ferme le DispatchIO (donc le fd)
    /// sans envoyer de signal.
    func release(id: UUID) {
        cancelPendingSend(id: id)
        guard let term = views[id] else { return }
        term.processDelegate = nil   // coupé d'abord : pas d'onProcessExit parasite
        if term.process?.running == true { term.terminate() }
        idByView[ObjectIdentifier(term)] = nil
        views[id] = nil
    }

    /// Quit de l'app : hardKill de tous les process vivants + libération de tout.
    /// SIGKILL explicite des **groupes** : la fermeture du fd maître (via
    /// `terminate()`) ne SIGHUPe pas un dev server qui l'ignore.
    func terminateAll() {
        for id in Array(views.keys) where isRunning(id: id) {
            hardKill(id: id)
        }
        for id in Array(views.keys) { release(id: id) }
    }

    // MARK: - Commande / shell

    /// `cd '<dossier>' && <command>; exit` + retour chariot (vaut une frappe
    /// « Entrée »). Échappement shell de l'apostrophe (`'` → `'\''`) sur le
    /// chemin ; `command` arrive **déjà échappé** (`PackageManager.runCommand`).
    /// `; exit` (et PAS `&&`) → le shell meurt même si le script échoue ; `exit`
    /// sans argument propage `$?` → le statut du script remonte tel quel.
    private static func scriptCommand(packageDir: URL, command: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        return "cd '\(esc(packageDir.path))' && \(command); exit\r"
    }

    private static func userShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let term = source as? LocalProcessTerminalView else { return }
        let oid = ObjectIdentifier(term)
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.idByView[oid] else { return }
            // Vue CONSERVÉE (scrollback lisible) ; statut waitpid transmis BRUT,
            // le décodage appartient à `ScriptRun.decodeWaitStatus`.
            self.onProcessExit?(id, exitCode)
        }
    }
}
