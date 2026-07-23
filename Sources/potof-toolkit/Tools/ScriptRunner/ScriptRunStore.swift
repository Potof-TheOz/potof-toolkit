import Foundation
import Combine

/// Source de vérité UI des exécutions de scripts. Possède le
/// `ScriptTerminalController` côté logique (câblage `onProcessExit`) et pilote la
/// séquence d'arrêt propre.
///
/// ⭐ **Singleton app-level, pas un `@StateObject`** : `RootView` détruit la vue de
/// l'outil (et ses `@StateObject`) au changement d'outil ; les runs — process
/// vivants, terminaux, statuts, sélection — doivent y survivre. Invariant :
/// **changer d'outil ne perd jamais un terminal**. Observer via `@ObservedObject`.
///
/// Non annoté `@MainActor` (convention du projet) : toutes les mutations passent
/// par le thread principal (actions UI + callbacks déjà remarshalés).
final class ScriptRunStore: ObservableObject {
    static let shared = ScriptRunStore()

    @Published private(set) var runs: [ScriptRun] = []
    /// Sélection du centre de l'outil (package OU run). Vit ici — et pas en
    /// `@State` dans la vue — pour survivre au switch d'outil.
    @Published var selection: Selection?

    enum Selection: Hashable {
        /// `ScriptPackage.id` (chemin absolu du dossier).
        case package(String)
        case run(UUID)
    }

    let terminal = ScriptTerminalController.shared

    // MARK: - État privé de la machine d'arrêt / fermeture

    /// Runs dont l'arrêt propre est armé. Présence dans le Set = poll actif
    /// (le retirer **désarme** les ticks à venir — pas de timer fantôme).
    private var stoppingIDs: Set<UUID> = []

    /// Cadence du poll d'arrêt (étape (b)) et tick de l'escalade SIGKILL
    /// (étape (c)) : 6 ticks × 0,5 s ≈ 3 s de grâce avant `hardKill`.
    private static let stopPollInterval: TimeInterval = 0.5
    private static let hardKillAttempt = 6

    /// Runs au process encore vivant dont la **fermeture** a été demandée : la
    /// libération de la vue + le retrait de la liste attendent la mort réelle
    /// (`handleExit`) — jamais de vue zombie ni de run retiré process vivant.
    private var pendingClose: Set<UUID> = []

    private init() {
        // Fin de process (déjà remarshalée sur main par le contrôleur) : statut
        // waitpid BRUT → décodage + badge ici ; la vue terminal est conservée.
        terminal.onProcessExit = { [weak self] id, raw in
            self?.handleExit(id, raw)
        }
    }

    /// Run encore actif (`.running`/`.stopping`) pour (packageDir, script), s'il
    /// existe. Un run dont la **fermeture** est demandée (`pendingClose`) ne compte
    /// plus : sinon « Fermer » puis ▶ immédiat serait dédupliqué sur le run mourant
    /// et le relancement avalé.
    func activeRun(packageDir: URL, script: String) -> ScriptRun? {
        runs.first {
            $0.status.isActive
                && !pendingClose.contains($0.id)
                && $0.packageDir.path == packageDir.path
                && $0.scriptName == script
        }
    }

    /// Lance `script` depuis `packageDir` (manager détecté par lockfile à
    /// `projectRoot`) et sélectionne le run. **Dédup** : un run actif existe déjà
    /// pour (packageDir, script) → simple focus, pas de second lancement.
    func launch(packageDir: URL, projectRoot: URL, projectName: String, script: String) {
        // Sécurité : la commande est *tapée* dans un shell interactif (ZLE), pas
        // passée à `exec`. Un nom de script ou un chemin contenant des caractères
        // de contrôle (`\u{15}` kill-line, `\n`, ESC…) serait interprété comme des
        // frappes — un `package.json` piégé (repo cloné hostile) pourrait injecter
        // une commande au simple clic ▶. L'échappement single-quote ne protège que
        // du parser, pas de la line discipline → on refuse en amont.
        guard Self.isSafeForPTY(script), Self.isSafeForPTY(packageDir.path) else { return }

        if let existing = activeRun(packageDir: packageDir, script: script) {
            focus(existing.id)
            return
        }
        let id = UUID()
        // Lockfile local au package d'abord, fallback sur la racine du projet
        // (monorepo sans lockfile local) : un sous-dossier vendored peut avoir son
        // propre gestionnaire, et le badge de `PackageDetailView` doit s'accorder.
        let manager = PackageManager.detect(packageDir: packageDir, projectRoot: projectRoot)
        terminal.start(id: id, packageDir: packageDir, command: manager.runCommand(script: script))
        runs.append(
            ScriptRun(
                id: id,
                packageDir: packageDir,
                projectName: projectName,
                scriptName: script,
                // Libellé d'affichage (header/sidebar) : lisible, PAS échappé —
                // la commande réellement exécutée vient de `runCommand`.
                commandLabel: "\(manager.rawValue) run \(script)",
                status: .running
            )
        )
        selection = .run(id)
    }

    /// Arrêt propre gradué : (a) Ctrl-C → statut `.stopping` ; (b) `exit\r` quand
    /// le shell est revenu au prompt ; (c) hardKill à ~3 s si toujours vivant.
    func stop(_ id: UUID) {
        // `.stopping` → no-op (machine déjà armée) ; fermeture en attente → le
        // hardKill est déjà parti, inutile d'armer un arrêt propre par-dessus.
        guard let i = runs.firstIndex(where: { $0.id == id }),
              runs[i].status == .running,
              !pendingClose.contains(id) else { return }

        // (a) Ctrl-C (0x03) → la line discipline (ISIG) délivre SIGINT au groupe
        // de premier plan : le script ET ses enfants (vite/esbuild…).
        runs[i].status = .stopping
        stoppingIDs.insert(id)
        terminal.sendInterrupt(id: id)
        schedulePollTick(id, attempt: 1)
    }

    /// Ferme le run : l'arrête d'abord s'il vit encore (hardKill), puis libère le
    /// terminal et retire l'entrée.
    func close(_ id: UUID) {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        // Retour naturel au détail du package si le run fermé était affiché.
        if selection == .run(id) { selection = .package(run.packageDir.path) }

        if terminal.isRunning(id: id) {
            // Process vivant → SIGKILL immédiat ; libération + retrait DIFFÉRÉS à
            // la mort réelle (`handleExit`), pour ne jamais libérer une vue dont
            // le process tourne encore. Un éventuel poll d'arrêt en cours est
            // désarmé : l'escalade n'a plus d'objet. On bascule le statut en
            // `.stopping` (le run va disparaître à sa mort) pour arrêter le pulse
            // « En cours » pendant la fenêtre — la dédup l'ignore déjà via
            // `pendingClose`.
            stoppingIDs.remove(id)
            if let i = runs.firstIndex(where: { $0.id == id }) { runs[i].status = .stopping }
            pendingClose.insert(id)
            terminal.hardKill(id: id)
        } else {
            // Run terminé (`.exited`/`.killed`) → libération + retrait immédiats.
            // `remove` sur les deux Sets couvre le double-« Fermer » (1er clic
            // process vivant → inséré ; EOF avant l'exit event → 2ᵉ clic passe
            // ici) : sans ça, l'id fuiterait pour la vie de l'app.
            pendingClose.remove(id)
            stoppingIDs.remove(id)
            terminal.release(id: id)
            removeRun(id)
        }
    }

    /// Affiche le run au centre.
    func focus(_ id: UUID) {
        selection = .run(id)
    }

    // MARK: - Fin de process

    /// Fin du process d'un run (callback du contrôleur, sur main). Décode le
    /// statut waitpid brut, pose le badge — la vue terminal est **CONSERVÉE**
    /// (scrollback lisible), le run reste listé — et finalise une éventuelle
    /// fermeture en attente.
    private func handleExit(_ id: UUID, _ raw: Int32?) {
        let wasStopping = runs.first(where: { $0.id == id })?.status == .stopping
        // Désarme la machine d'arrêt : les ticks de poll encore planifiés se
        // verront désarmés à leur réveil (pas de timer fantôme).
        stoppingIDs.remove(id)

        if let i = runs.firstIndex(where: { $0.id == id }) {
            var status = ScriptRun.decodeWaitStatus(raw)
            // Normalisation « arrêté par l'utilisateur » : après notre Ctrl-C, le
            // shell propage le plus souvent `exit 130` (= 128 + SIGINT) — un statut
            // *exited* côté waitpid alors que, sémantiquement, l'utilisateur a
            // arrêté le script. On le requalifie en `.killed(signal: SIGINT)` pour
            // que l'UI (B2) affiche « arrêté » (gris) et non une erreur rouge
            // (130 ≠ 0). Hors `.stopping`, le statut décodé est gardé tel quel.
            if wasStopping, case .exited(let code) = status, code == 130 {
                status = .killed(signal: SIGINT)
            }
            runs[i].status = status
        }

        // `close` demandé pendant que le process vivait → maintenant que la mort
        // est réelle, libération de la vue + retrait du run (pas de vue zombie).
        if pendingClose.remove(id) != nil {
            terminal.release(id: id)
            removeRun(id)
        }
    }

    // MARK: - Machine d'arrêt (étapes (b)/(c))

    private func schedulePollTick(_ id: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopPollInterval) { [weak self] in
            self?.pollStop(id, attempt: attempt)
        }
    }

    /// Un tick du poll d'arrêt (toutes les 0,5 s, main queue — pattern
    /// `SessionStore.confirmEditInTerminal`). Se **désarme** dès que le run a été
    /// fermé/terminé entre-temps (guards ci-dessous) : aucun timer fantôme.
    private func pollStop(_ id: UUID, attempt: Int) {
        // Machine désarmée (handleExit / close) ou run disparu / plus en arrêt.
        guard stoppingIDs.contains(id),
              runs.first(where: { $0.id == id })?.status == .stopping else { return }

        // Process mort : `handleExit` finalise (ou vient de finaliser) le badge.
        guard terminal.isRunning(id: id) else {
            stoppingIDs.remove(id)
            return
        }

        // (c) ~3 s de grâce écoulées, toujours vivant (SIGINT ignoré ou shutdown
        // interminable) → SIGKILL du job entier puis du shell. Le monitor livrera
        // l'exit (raw = 9) → badge `.killed(signal: 9)` via `handleExit`, qui
        // désarmera la machine. On ne re-planifie donc plus rien ici.
        guard attempt < Self.hardKillAttempt else {
            terminal.hardKill(id: id)
            return
        }

        // (b) le shell est revenu au prompt (zsh interactif JETTE le `; exit` de
        // la ligne après un Ctrl-C) → `exit\r`. Le garde `shellAtPrompt` évite
        // d'écrire « exit » dans le stdin d'un script en shutdown gracieux. On
        // retente à CHAQUE tick tant qu'on est au prompt : zsh peut refuser le
        // 1er `exit` (« you have suspended jobs » si l'utilisateur a fait Ctrl-Z
        // dans le terminal) et l'accepter au suivant. Les envois surnuméraires
        // après la mort du shell retombent sur le garde `running` du contrôleur.
        if terminal.shellAtPrompt(id: id) {
            terminal.sendExit(id: id)
        }
        schedulePollTick(id, attempt: attempt + 1)
    }

    // MARK: - Privé

    /// Retire le run de la liste et garantit que la sélection ne pointe jamais un
    /// run disparu (l'utilisateur a pu re-cliquer le run entre la demande de
    /// fermeture et la mort réelle du process) → retour au détail du package.
    private func removeRun(_ id: UUID) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        let packagePath = runs[i].packageDir.path
        runs.remove(at: i)
        if selection == .run(id) { selection = .package(packagePath) }
    }

    /// Vrai si `s` ne contient aucun caractère de contrôle : la commande étant
    /// *tapée* dans un PTY interactif, un tel caractère serait une frappe (ESC,
    /// kill-line, retour chariot…) échappant à l'échappement single-quote.
    private static func isSafeForPTY(_ s: String) -> Bool {
        s.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
