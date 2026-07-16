import Foundation

/// Émise quand un `CLAUDE.md` vient d'être écrit via « Initialiser CLAUDE.md », pour que
/// la liste de dossiers rafraîchisse son drapeau `hasClaudeMd` (figé au scan) et cesse de
/// proposer « Initialiser » sur un dossier désormais pourvu.
extension Notification.Name {
    static let initClaudeMdDidWriteFile = Notification.Name("PotofToolkit.initClaudeMdDidWriteFile")
}

/// Orchestre l'initialisation d'un `CLAUDE.md` sur un dossier qui n'en a pas encore,
/// via une session `claude` possédée. Déclenché par « Initialiser CLAUDE.md… » (clic
/// droit sur un dossier candidat). Déroulé :
///
///  1. `begin(sessionID:folder:)` — la session vient d'être lancée. Le pont IDE doit
///     être disponible (garanti par l'appelant `SessionStore`), sinon `openDiff` n'est
///     jamais émis et l'aperçu Accepter/Refuser — dont dépend toute la séquence — manque.
///  2. `ideConnected(sessionID:)` — `claude` s'est connecté au pont IDE (donc booté,
///     après un éventuel prompt « trust this folder ») → **seul** signal qui déclenche
///     `/init`. On ne seed **jamais** à l'aveugle : taper `/init` dans un shell qui
///     pourrait être nu produit « zsh: no such file: /init ».
///  3. Claude propose le `CLAUDE.md` via `openDiff` → l'utilisateur accepte
///     (`SessionStore.resolveDiff(.saved)` → `diffSaved(...)`) ou refuse (→ `diffRejected`).
///  4. Une fois le fichier accepté (et « Yes » répondu au prompt de permission), on
///     attend que Claude soit de nouveau prêt, puis on injecte les **conventions maison**
///     (`ConventionsProfile.augmentationPrompt()`), si tant est qu'il y en ait.
///  5. Le second `openDiff` (accepté) clôt l'orchestration.
///
/// L'app **n'écrit jamais** : tout passe par l'aperçu Accepter/Refuser du pont IDE
/// (cf. docs/IDE_BRIDGE.md). Machine à états par session, mutations sur le thread
/// principal (comme le reste du projet). Se compose avec la feature `resume` sans y
/// toucher : on ne fait qu'envoyer des frappes à une session déjà lancée.
final class InitClaudeMdCoordinator {
    static let shared = InitClaudeMdCoordinator()
    private init() {}

    private enum Phase { case awaitingInit, awaitingAugment }
    /// État par session : phase courante + **chemin exact** du `CLAUDE.md` visé. Le
    /// chemin sert à n'accepter QUE l'aperçu du bon fichier (pas un `docs/CLAUDE.md`
    /// imbriqué ni un `MYCLAUDE.md`).
    private struct SessionState { var phase: Phase; let claudeMdPath: String }
    private var states: [UUID: SessionState] = [:]
    /// Sessions dont `/init` a déjà été envoyé (évite un double envoi si le handshake
    /// IDE se répète).
    private var seeded: Set<UUID> = []
    /// Sessions dont le pont IDE a répondu (handshake). Sert à **désarmer le filet** :
    /// `seedInit` n'est appelé qu'après `connectSettle`, donc un handshake tardif serait
    /// écrasé par `abortIfNeverConnected` s'il ne se basait que sur `seeded`.
    private var connected: Set<UUID> = []

    private let pollInterval: TimeInterval = 0.25
    private let readyCap = 80               // ~20 s de scrutation « prêt » avant abandon
    private let connectSettle: TimeInterval = 0.8   // laisse le prompt se dessiner après connexion
    private let saveSettle: TimeInterval = 1.0      // laisse Claude enchaîner l'écriture avant de guetter l'idle
    private let connectTimeout: TimeInterval = 15   // abandon si le pont IDE ne se connecte jamais
    private let enterDelay: TimeInterval = 0.4       // délai entre le texte et la touche Entrée

    // MARK: - Cycle

    /// Session lancée pour une init sur `folder`. On attend la connexion du pont IDE
    /// pour seeder `/init` ; si elle n'arrive jamais, on **abandonne sans rien taper**.
    func begin(sessionID id: UUID, folder: URL) {
        states[id] = SessionState(phase: .awaitingInit, claudeMdPath: Self.claudeMdPath(in: folder))
        seeded.remove(id)
        IDELog.log("init CLAUDE.md: session \(id.uuidString) — /init à la connexion du pont IDE")
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            self?.abortIfNeverConnected(id)
        }
    }

    /// Le pont IDE ne s'est jamais connecté dans le délai ⇒ `claude` n'a pas booté comme
    /// attendu (absent du PATH, échec de démarrage…). On **abandonne** : ne JAMAIS
    /// seeder `/init` à l'aveugle sur un shell potentiellement nu.
    private func abortIfNeverConnected(_ id: UUID) {
        // `seeded` ⊆ `connected` (on ne seed qu'après connexion) → tester `connected` suffit.
        guard states[id]?.phase == .awaitingInit, !connected.contains(id) else { return }
        IDELog.log("init CLAUDE.md: pont IDE non connecté après \(Int(connectTimeout)) s → init abandonnée (rien saisi)")
        clear(id)
    }

    /// Le pont IDE de la session est connecté ⇒ `claude` a booté → on seed `/init`.
    func ideConnected(sessionID id: UUID) {
        guard states[id]?.phase == .awaitingInit, !seeded.contains(id) else { return }
        // Marqué AVANT le délai : un handshake tardif ne doit plus être écrasé par le filet.
        connected.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + connectSettle) { [weak self] in
            self?.seedInit(id)
        }
    }

    private func seedInit(_ id: UUID) {
        guard states[id]?.phase == .awaitingInit, !seeded.contains(id) else { return }
        guard TerminalController.shared.view(for: id) != nil else { clear(id); return }
        seeded.insert(id)
        IDELog.log("init CLAUDE.md: seed /init (pont IDE connecté)")
        sendWhenReady(id, text: "/init", phase: .awaitingInit)
    }

    /// Un `openDiff` vient d'être **accepté** (« Yes » répondu au prompt de permission).
    /// Si c'est la session d'init et l'aperçu du `CLAUDE.md` visé : après `/init` →
    /// injection des conventions (si présentes) ; après l'augmentation → fin. Tout autre
    /// fichier / session non-init est ignoré.
    func diffSaved(sessionID id: UUID, request: IDEDiffRequest) {
        guard let state = states[id], isTargetClaudeMd(request, state: state) else { return }
        switch state.phase {
        case .awaitingInit:
            // Le fichier vient d'apparaître sur disque → la liste de dossiers peut
            // rafraîchir son drapeau `hasClaudeMd`. (Inutile de re-poster à l'augmentation :
            // le fichier existe déjà, le drapeau est déjà à jour.)
            NotificationCenter.default.post(name: .initClaudeMdDidWriteFile, object: nil)
            guard let prompt = ConventionsProfile.augmentationPrompt() else {
                IDELog.log("init CLAUDE.md: /init accepté, aucune convention à injecter → terminé")
                clear(id)
                return
            }
            states[id]?.phase = .awaitingAugment
            IDELog.log("init CLAUDE.md: /init accepté → injection des conventions maison")
            DispatchQueue.main.asyncAfter(deadline: .now() + saveSettle) { [weak self] in
                self?.sendWhenReady(id, text: prompt, phase: .awaitingAugment)
            }
        case .awaitingAugment:
            IDELog.log("init CLAUDE.md: conventions appliquées — terminé")
            clear(id)
        }
    }

    /// L'utilisateur a **refusé** l'aperçu (ou Claude a fermé l'onglet). Si c'est l'aperçu
    /// du `CLAUDE.md` visé pendant une init : on **désarme**. Sans ça, le coordinateur
    /// resterait en `awaitingInit` et injecterait les conventions au prochain `CLAUDE.md`
    /// accepté — même longtemps après, sur une frappe que l'utilisateur n'a pas demandée.
    func diffRejected(sessionID id: UUID, request: IDEDiffRequest) {
        guard let state = states[id], isTargetClaudeMd(request, state: state) else { return }
        IDELog.log("init CLAUDE.md: aperçu du CLAUDE.md refusé → init abandonnée")
        clear(id)
    }

    /// Abandon inconditionnel (ex. session fermée). Appelé par `SessionStore.remove`.
    func cancel(sessionID id: UUID) {
        guard states[id] != nil else { return }
        IDELog.log("init CLAUDE.md: session \(id.uuidString) fermée → init annulée")
        clear(id)
    }

    private func clear(_ id: UUID) { states[id] = nil; seeded.remove(id); connected.remove(id) }

    // MARK: - Envoi quand claude est prêt à recevoir un prompt

    /// Envoie `text` dès que `claude` est **prêt** (`ClaudePromptHeuristics.readyForInput`).
    /// Trois gardes essentielles :
    ///  - la session doit être **encore dans la phase attendue** (sinon une frappe
    ///    programmée après un `clear`/changement de phase parlerait dans le vide) ;
    ///  - si l'état « prêt » n'est pas détecté avant `readyCap`, on **abandonne** au lieu
    ///    d'envoyer en « best effort » — envoyer pendant un prompt « trust this folder »
    ///    ou pendant que Claude travaille taperait le texte dans le mauvais contexte ;
    ///  - n'est atteint qu'une fois `claude` connu démarré (connexion IDE), donc pas de
    ///    faux positif « prêt » sur un shell nu.
    private func sendWhenReady(_ id: UUID, text: String, phase: Phase, attempt: Int = 0) {
        guard states[id]?.phase == phase else { return }   // désarmé / phase changée → abandon silencieux
        let tc = TerminalController.shared
        guard tc.view(for: id) != nil else { clear(id); return }
        if ClaudePromptHeuristics.readyForInput(tc.screenText(id: id)) {
            submit(id, text)
            return
        }
        guard attempt < readyCap else {
            IDELog.log("init CLAUDE.md: état « prêt » non détecté après délai → abandon (rien saisi)")
            clear(id)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.sendWhenReady(id, text: text, phase: phase, attempt: attempt + 1)
        }
    }

    /// Envoie le prompt, puis la touche **Entrée séparément** après un court délai. Un
    /// `\r` accolé au texte (même write) n'est pas interprété comme « soumettre » par la
    /// TUI de claude : le menu de commandes slash (pour `/init`) ou le collage long
    /// (pour les conventions) l'absorbe. Laisser le champ se stabiliser reproduit la
    /// frappe humaine (taper, puis Entrée). `sendKeys` est no-op si la session est morte.
    private func submit(_ id: UUID, _ text: String) {
        TerminalController.shared.sendKeys(id: id, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDelay) {
            TerminalController.shared.sendKeys(id: id, "\r")
        }
    }

    // MARK: - Ciblage du fichier

    /// L'aperçu porte-t-il **exactement** sur le `CLAUDE.md` visé par cette init ?
    /// Comparaison par chemin normalisé (résolution des liens symboliques + standardisé),
    /// pas par `hasSuffix("CLAUDE.md")` : ce dernier matchait aussi `docs/CLAUDE.md` ou
    /// `MYCLAUDE.md` et faisait avancer/clore la machine à états sur le mauvais fichier.
    private func isTargetClaudeMd(_ request: IDEDiffRequest, state: SessionState) -> Bool {
        Self.normalize(request.newPath) == state.claudeMdPath
            || Self.normalize(request.oldPath) == state.claudeMdPath
    }

    private static func claudeMdPath(in folder: URL) -> String {
        normalize(folder.appendingPathComponent("CLAUDE.md").path)
    }

    /// Réutilise la normalisation de `SessionStore` (résolution symlinks + standardisé),
    /// avec un garde pour le chemin vide (`oldPath` peut l'être pour un fichier neuf).
    private static func normalize(_ path: String) -> String {
        path.isEmpty ? "" : SessionStore.normalized(path)
    }
}
