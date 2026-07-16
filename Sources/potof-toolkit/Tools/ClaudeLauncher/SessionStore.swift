import Foundation
import Combine

/// Source de vérité des sessions Claude embarquées pour la couche SwiftUI.
/// Possède le `TerminalController` qui gère les vues/process AppKit.
///
/// Non annoté `@MainActor` volontairement (le projet n'utilise aucune annotation
/// de concurrence) : par construction, toutes les mutations passent par le thread
/// principal — actions UI + callbacks du controller déjà remarshalés sur `main`.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var activeID: UUID?
    /// Aperçus de diff en attente de décision, par session (intégration IDE).
    /// L'UI en affiche un overlay au-dessus du terminal de la session active.
    @Published private(set) var pendingDiffs: [UUID: DiffPresentation] = [:]

    let terminal = TerminalController.shared

    init() {
        terminal.onTitleChange = { [weak self] id, title in
            self?.updateTitle(id, title)
        }
        terminal.onProcessExit = { [weak self] id, code in
            self?.handleExit(id, code)
        }
        // Intégration IDE : Claude propose un diff / ferme un onglet de diff.
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

    /// Claude propose une modification (`openDiff`, bloquant côté CLI) : on calcule
    /// le diff vs le disque, on le met en attente et on bascule sur la session
    /// concernée pour le rendre visible. L'app **n'écrit rien** : c'est le verdict
    /// (`resolveDiff`) qui, si accepté, laisse Claude écrire.
    private func presentDiff(_ id: UUID, _ request: IDEDiffRequest,
                             _ complete: @escaping (IDEDiffVerdict) -> Void) {
        // Session déjà fermée entre-temps → refuse, sinon Claude resterait bloqué.
        guard containsSession(id) else { complete(.rejected); return }
        // Un aperçu déjà en attente (ne devrait pas arriver : les openDiff sont
        // sérialisés) → on le refuse avant de le remplacer, pas de complétion perdue.
        if let stale = pendingDiffs[id] { stale.complete(.rejected) }
        let diff = DiffComputer.compute(oldPath: request.oldPath, newContent: request.newContents)
        pendingDiffs[id] = DiffPresentation(sessionID: id, request: request, diff: diff, complete: complete)
        IDELog.log("présente diff (+\(diff.addedCount)/−\(diff.removedCount)) : \(request.tabName)")
        focus(id)
    }

    /// Décision de l'utilisateur (clic Accepter/Refuser dans le panneau).
    ///
    /// Subtilité clé (cf. docs/IDE_BRIDGE.md) : `openDiff` n'est qu'un **aperçu**.
    /// En mode permission par défaut, Claude affiche APRÈS un prompt terminal
    /// « Do you want to make this edit? 1. Yes / 3. No ». C'est LUI la vraie porte.
    /// Donc : Refuser → `DIFF_REJECTED` (Claude abandonne, aucun prompt) ; Accepter →
    /// `FILE_SAVED` puis on répond « Yes » à ce prompt (`confirmEditInTerminal`).
    func resolveDiff(_ id: UUID, _ verdict: IDEDiffVerdict) {
        guard let pres = pendingDiffs[id] else { return }
        pendingDiffs[id] = nil          // ferme le panneau ; `remove` ne re-votera pas
        IDELog.log("verdict utilisateur : \(verdict.rawValue)")
        pres.complete(verdict)
        if verdict == .saved {
            // On répond « Yes » au prompt de permission PUIS, une fois seulement ce Yes
            // envoyé, on prévient le coordinateur d'init : sinon l'injection des conventions
            // (planifiée sur un délai fixe) pouvait partir avant même que le prompt de
            // permission ne s'affiche, et taper dans le mauvais contexte.
            confirmEditInTerminal(id, attempt: 0) { [weak self] in
                guard self != nil else { return }
                InitClaudeMdCoordinator.shared.diffSaved(sessionID: id, request: pres.request)
            }
        } else {
            // Refus explicite → désarme une éventuelle init en cours sur cette session.
            InitClaudeMdCoordinator.shared.diffRejected(sessionID: id, request: pres.request)
        }
    }

    /// Répond « Yes » (Entrée) au prompt de permission terminal qui suit `FILE_SAVED`.
    /// On **détecte** l'apparition du prompt dans le buffer rendu (robuste au timing :
    /// il apparaît généralement en < 1 s, mais on tolère un délai) ; en dernier
    /// recours (~6 s) on envoie quand même Entrée (le prompt est alors forcément là).
    private func confirmEditInTerminal(_ id: UUID, attempt: Int, then: (() -> Void)? = nil) {
        guard containsSession(id) else { return }
        if ClaudePromptHeuristics.permissionPromptVisible(terminal.screenText(id: id)) {
            terminal.sendKeys(id: id, "\r")   // « ❯ 1. Yes » est le défaut → Entrée = Yes
            IDELog.log("prompt de permission détecté → Entrée (Yes)")
            then?()
            return
        }
        guard attempt < 40 else {             // ~6 s : dernier recours (best effort)
            terminal.sendKeys(id: id, "\r")
            IDELog.log("prompt non détecté après délai → Entrée (best effort)")
            then?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.confirmEditInTerminal(id, attempt: attempt + 1, then: then)
        }
    }

    /// Claude a fermé l'onglet (annulation, ex. Ctrl-C) alors que l'aperçu était
    /// encore ouvert → on le retire en refusant. `matchingTab == nil` ⇒ tout fermer.
    private func dismissDiff(_ id: UUID, matchingTab tab: String?) {
        guard let pres = pendingDiffs[id] else { return }
        if let tab, pres.request.tabName != tab { return }
        pendingDiffs[id] = nil
        pres.complete(.rejected)
        // Claude a annulé l'aperçu → désarme une éventuelle init en cours.
        InitClaudeMdCoordinator.shared.diffRejected(sessionID: id, request: pres.request)
    }

    // MARK: - Privé

    private func remove(_ id: UUID) {
        // Session fermée avec un diff en attente → on refuse (libère le CLI).
        if let pres = pendingDiffs[id] {
            pendingDiffs[id] = nil
            pres.complete(.rejected)
        }
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

// MARK: - Aperçu de diff en attente

/// Un `openDiff` en attente de décision, pour une session. Porte la complétion à
/// rappeler avec le verdict (renvoyé au CLI Claude via le pont IDE). Le `diff` est
/// pré-calculé à la réception ; la vue ne fait que l'afficher.
struct DiffPresentation: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let request: IDEDiffRequest
    let diff: FileDiff
    let complete: (IDEDiffVerdict) -> Void
}

// MARK: - Fournisseur de sessions pour les notifications

extension SessionStore: NotificationSessionProviding {
    func containsSession(_ id: UUID) -> Bool { sessions.contains { $0.id == id } }
    var activeSessionID: UUID? { activeID }
    /// Ignore une session déjà morte (sinon `activeID` pointerait dans le vide).
    func focusSession(_ id: UUID) { if containsSession(id) { focus(id) } }
}
