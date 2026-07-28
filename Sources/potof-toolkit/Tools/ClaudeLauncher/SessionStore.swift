import Foundation
import Combine

/// Source de vérité des sessions Claude embarquées pour la couche SwiftUI.
/// Possède le `TerminalController` qui gère les vues/process AppKit.
///
/// Non annoté `@MainActor` volontairement (le projet n'utilise aucune annotation
/// de concurrence) : par construction, toutes les mutations passent par le thread
/// principal — actions UI + callbacks du controller déjà remarshalés sur `main`.
final class SessionStore: ObservableObject {
    /// Singleton app-level : `RootView` détruit la vue de l'outil (et ses
    /// `@StateObject`) au switch d'outil, alors que les sessions sont des process
    /// vivants dans `TerminalController.shared`. Sans singleton, revenir sur
    /// l'outil repartirait d'une liste vide (terminaux orphelins invisibles).
    /// Invariant : changer d'outil ne perd jamais un terminal.
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = []
    @Published var activeID: UUID?

    let terminal = TerminalController.shared

    private init() {
        terminal.onTitleChange = { [weak self] id, title in
            self?.updateTitle(id, title)
        }
        terminal.onProcessExit = { [weak self] id, code in
            self?.handleExit(id, code)
        }
        // Intégration IDE : Claude propose un diff / ferme un onglet de diff. Les
        // demandes ne sont plus gardées ici : elles partent dans `DiffReviewCenter`,
        // la file d'attente **unique** de l'app (cf. `Core/DiffReview/`).
        terminal.onOpenDiff = { [weak self] id, req, done in
            self?.presentDiff(id, req, done)
        }
        terminal.onCloseTab = { [weak self] id, tab in
            self?.dismissDiff(id, matchingTab: tab)
        }
        terminal.onCloseAllTabs = { [weak self] id in
            self?.dismissDiff(id, matchingTab: nil)
        }
        // Init CLAUDE.md : la connexion du pont IDE signale que `claude` a booté.
        terminal.onIDEConnected = { id in
            InitClaudeMdCoordinator.shared.ideConnected(sessionID: id)
        }
    }

    var activeSession: Session? { sessions.first { $0.id == activeID } }

    /// Chemins normalisés des dossiers ayant au moins une session en cours.
    var runningFolderPaths: Set<String> {
        Set(sessions.map { Self.normalized($0.folderURL.path) })
    }

    // MARK: - Actions

    /// Lance une nouvelle session dans `folder` et l'active. `resume` (id de
    /// conversation Claude) ⇒ reprise d'une session précédente (`claude --resume`).
    func launch(folder: URL, resume: String? = nil) {
        let id = UUID()
        sessions.append(
            Session(id: id, folderURL: folder, title: folder.lastPathComponent, status: .running)
        )
        terminal.start(id: id, folder: folder, resume: resume)
        activeID = id
    }

    /// Lance une session pour **initialiser un `CLAUDE.md`** (dossier sans fichier) :
    /// démarre `claude` normalement, puis confie à l'`InitClaudeMdCoordinator` le soin
    /// de seeder `/init` et, une fois le fichier accepté, d'injecter les conventions
    /// maison. Réutilise `launch` tel quel (pas de `resume`).
    ///
    /// L'auto-init n'est armée que si le **pont IDE est disponible** pour la session :
    /// sans lui, `claude` n'émet pas d'`openDiff`, donc pas d'aperçu Accepter/Refuser
    /// dont dépend toute la séquence. Sinon, la session est simplement lancée (l'utilisateur
    /// peut faire `/init` à la main) et on le journalise, plutôt que de seeder dans le vide.
    func launchInitializingClaudeMd(folder: URL) {
        launch(folder: folder)
        guard let id = activeID else { return }
        guard terminal.hasIDEBridge(id: id) else {
            IDELog.log("init CLAUDE.md: pont IDE indisponible → auto-init désactivée (session lancée normalement)")
            return
        }
        InitClaudeMdCoordinator.shared.begin(sessionID: id, folder: folder)
    }

    /// Ferme une session : **tue le process** puis retire l'entrée.
    func close(_ id: UUID) {
        terminal.terminate(id: id)
        remove(id)
    }

    /// Affiche la session `id` au centre. **Programmatique et neutre** : ne touche
    /// pas aux notifications. `presentDiff` (openDiff) l'appelle sans intention de
    /// l'utilisateur → le nettoyage de la cloche se fait dans `reveal(_:)`.
    func focus(_ id: UUID) { activeID = id }

    /// Focus **déclenché par l'utilisateur** (clic sur une session dans la sidebar) :
    /// affiche la session ET nettoie ses notifications (le focus vaut « j'ai vu »).
    /// Le clic sur une *notification* passe, lui, par `handleClick` côté coordinateur
    /// (qui nettoie aussi, y compris pour une session déjà fermée).
    func reveal(_ id: UUID) {
        focus(id)
        NotificationCenterCoordinator.shared.sessionDidFocus(id)
    }

    // MARK: - Aperçu de diff (intégration IDE, cf. docs/IDE_BRIDGE.md)

    /// Claude propose une modification (`openDiff`, bloquant côté CLI) : la demande
    /// part dans `DiffReviewCenter`, la **file d'attente unique** de l'app, affichée
    /// par la fenêtre flottante de revue. Une session possédée et un agent externe
    /// (Superset) empruntent donc exactement la même surface de validation ; le
    /// terminal, lui, reste visible en permanence.
    ///
    /// L'app **n'écrit rien** : c'est le verdict qui, si accepté, laisse `claude`
    /// écrire le contenu qu'on lui renvoie (§2.3 du contrat).
    private func presentDiff(_ id: UUID, _ request: IDEDiffRequest,
                             _ complete: @escaping (IDEDiffVerdict) -> Void) {
        // Session déjà fermée entre-temps → refuse, sinon Claude resterait bloqué.
        guard containsSession(id) else { complete(.rejected); return }
        // On **enveloppe** la complétion du protocole : quel que soit le chemin de
        // résolution (clic de l'utilisateur, `close_tab`, purge à la fermeture de la
        // session), la réponse part d'abord vers le CLI, puis les conséquences locales
        // sont traitées ici — un seul endroit, aucune branche oubliée.
        DiffReviewCenter.shared.enqueue(request: request, origin: diffOrigin(for: id)) {
            [weak self] verdict in
            complete(verdict)
            self?.didResolveDiff(id, request: request, verdict: verdict)
        }
    }

    /// Suites locales d'un verdict, une fois la réponse `openDiff` partie.
    ///
    /// ⚠️ **Plus aucun « Entrée » n'est envoyé au terminal en routine.** Fait vérifié
    /// sur `claude 2.1.220` (§2.3 du contrat, `tSd`) : quand la réponse `FILE_SAVED`
    /// est bien formée (deux blocs), le panneau de diff **EST** le prompt de
    /// permission — il rend un `allow`/`deny`, et **rien ne s'affiche dans le
    /// terminal**. L'ancien repli « au bout de ~6 s, tape Entrée quoi qu'il arrive »
    /// validerait aujourd'hui n'importe quel prompt présent à ce moment-là (« trust
    /// this folder », un `Bash` proposé entre-temps…) : il est supprimé.
    ///
    /// Reste une surveillance **conditionnelle** (cf. `watchStrayPermissionPrompt`),
    /// qui ne tape que sur détection et signale alors une dérive du contrat.
    private func didResolveDiff(_ id: UUID, request: IDEDiffRequest, verdict: IDEDiffVerdict) {
        switch verdict {
        case .saved:
            // Le « Yes » terminal ayant disparu, l'enchaînement de l'init CLAUDE.md
            // part **immédiatement après le verdict** : c'est désormais le verdict
            // lui-même qui débloque `claude` (il applique l'outil dans la foulée).
            InitClaudeMdCoordinator.shared.diffSaved(sessionID: id, request: request)
            watchStrayPermissionPrompt(id, request: request, attempt: 0)
        case .rejected:
            // Refus explicite, `close_tab`, ou session fermée → désarme une éventuelle
            // init en cours sur cette session (sinon elle injecterait les conventions
            // au prochain CLAUDE.md accepté, longtemps après et sans qu'on le demande).
            InitClaudeMdCoordinator.shared.diffRejected(sessionID: id, request: request)
        }
    }

    /// Filet de sécurité **conditionnel** après une acceptation : on regarde ~2 s si un
    /// prompt de permission apparaît malgré tout dans le terminal.
    ///
    /// En nominal il n'en apparaît **aucun** — c'est tout l'intérêt du contrat. Qu'il
    /// s'en affiche un veut dire que le CLI n'a pas pris notre revendication de
    /// permission (réponse mal formée, protocole modifié…) : dans ce cas seulement on
    /// répond `Entrée` (« ❯ 1. Yes » est l'option par défaut) pour ne pas laisser la
    /// session bloquée, **et** on lève le drapeau de dérive (bandeau + `ide.log`).
    ///
    /// Garde-fou anti-faux-positif : l'heuristique lit le buffer *rendu*, où un prompt
    /// déjà répondu peut encore traîner. On exige donc une véritable **apparition** —
    /// si l'écran montrait déjà un prompt au moment du verdict, on désarme la
    /// surveillance plutôt que de risquer une frappe à l'aveugle.
    private func watchStrayPermissionPrompt(_ id: UUID, request: IDEDiffRequest, attempt: Int) {
        guard containsSession(id) else { return }
        let promptVisible = ClaudePromptHeuristics.permissionPromptVisible(terminal.screenText(id: id))
        if attempt == 0 {
            guard !promptVisible else {
                IDELog.log("prompt déjà à l'écran au moment du verdict → surveillance désarmée "
                           + "(reliquat d'affichage indiscernable d'une dérive ; on ne tape jamais à l'aveugle)")
                return
            }
        } else if promptVisible {
            terminal.sendKeys(id: id, "\r")   // « ❯ 1. Yes » est le défaut → Entrée = Yes
            IDELog.log("DÉRIVE : prompt de permission apparu après FILE_SAVED → Entrée envoyée")
            IDEContractGuard.shared.flagDrift(
                "Un prompt de permission est apparu dans le terminal après une acceptation "
                + "(\(request.tabName)). Sur claude \(IDEProtocolContract.lastValidatedClaudeVersion) "
                + "le panneau de revue EST la permission : ce prompt signifie que la réponse "
                + "FILE_SAVED n'a pas été prise en compte. Répondu « Entrée » pour ne pas bloquer "
                + "la session — le contrat openDiff a probablement changé.")
            return
        }
        // ~2 s de veille (13 × 0,15 s) : au-delà, l'absence de prompt = comportement
        // nominal, on s'arrête en silence.
        guard attempt < Self.strayPromptPollCount else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.strayPromptPollInterval) { [weak self] in
            self?.watchStrayPermissionPrompt(id, request: request, attempt: attempt + 1)
        }
    }

    private static let strayPromptPollInterval: TimeInterval = 0.15
    private static let strayPromptPollCount = 13

    /// Claude a fermé l'onglet (annulation, ex. Ctrl-C) alors que la demande était
    /// encore dans la file → le centre la retire **en refusant** (l'appel bloquant
    /// doit recevoir une réponse). `matchingTab == nil` ⇒ tout fermer pour la session.
    private func dismissDiff(_ id: UUID, matchingTab tab: String?) {
        DiffReviewCenter.shared.dismiss(matchingTab: tab, origin: diffOrigin(for: id))
    }

    /// Origine d'une demande émise par cette session. `kind` porte l'identité
    /// **stable** (c'est sur elle que le centre apparie ses purges) ; `label` n'est
    /// que de l'affichage : titre courant de la session (OSC title de `claude`) ou,
    /// à défaut, nom du dossier.
    private func diffOrigin(for id: UUID) -> DiffReviewOrigin {
        let session = sessions.first { $0.id == id }
        let label = session.map { $0.title.isEmpty ? $0.folderName : $0.title } ?? "Session Claude"
        return DiffReviewOrigin(kind: .session(id), label: label)
    }

    // MARK: - Privé

    private func remove(_ id: UUID) {
        // Session fermée : plus personne pour lire nos réponses, et plus aucune UI
        // rattachée à cette origine. On purge la file **avant** de retirer la session,
        // pour que toute demande encore en vol reçoive son `DIFF_REJECTED` — sinon le
        // CLI resterait bloqué indéfiniment sur son appel `openDiff`.
        // (Chaque purge repasse par `didResolveDiff`, qui désarme l'init au passage.)
        DiffReviewCenter.shared.dropAll(origin: diffOrigin(for: id))
        // Désarme une éventuelle init en cours (sinon son état survit à la session).
        InitClaudeMdCoordinator.shared.cancel(sessionID: id)
        sessions.removeAll { $0.id == id }
        if activeID == id { activeID = sessions.last?.id }
    }

    private func updateTitle(_ id: UUID, _ title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        // On ne remplace pas par un titre vide ; sinon on garde le nom du dossier.
        sessions[i].title = title
    }

    /// Le process s'est terminé de lui-même (`claude` a quitté) → on libère la vue
    /// et on retire la session (fidèle à l'esprit « pas de session fantôme »).
    private func handleExit(_ id: UUID, _ code: Int32?) {
        terminal.terminate(id: id)
        remove(id)
    }

    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// `DiffPresentation` (l'aperçu en attente gardé ici, avec sa complétion) a disparu :
// la file d'attente est désormais **unique** et vit dans `DiffReviewCenter`
// (`PendingDiffReview`), partagée avec les agents externes servis par `IDEHost`.

// MARK: - Fournisseur de sessions pour les notifications

extension SessionStore: NotificationSessionProviding {
    func containsSession(_ id: UUID) -> Bool { sessions.contains { $0.id == id } }
    var activeSessionID: UUID? { activeID }
    /// Ignore une session déjà morte (sinon `activeID` pointerait dans le vide).
    func focusSession(_ id: UUID) { if containsSession(id) { focus(id) } }
}
