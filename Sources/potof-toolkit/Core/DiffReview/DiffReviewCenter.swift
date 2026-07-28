import Foundation
import Combine

/// D'où vient une demande de revue — sert à **regrouper** (purger tout ce qui vient
/// d'un client déconnecté) et à **afficher** de qui il s'agit.
///
/// `kind` porte l'identité stable ; `label` est du texte d'affichage qui peut se
/// préciser après coup (l'identité d'un client externe n'est connue qu'à l'arrivée de
/// `ide_connected`). Les appariements se font donc sur `kind`, jamais sur `label`.
struct DiffReviewOrigin: Hashable {
    enum Kind: Hashable {
        /// Un `claude` externe connecté à `IDEHost` (Superset, terminal du poste…).
        case externalClient(UUID)
        /// Une session possédée par le Claude Launcher.
        case session(UUID)
    }
    let kind: Kind
    /// Libellé lisible : « Superset · ma-branche », nom de la session…
    let label: String
}

/// Une demande `openDiff` en attente de décision.
///
/// ⚠️ `complete` **doit** être appelée exactement une fois : côté CLI, `openDiff` est
/// un appel **bloquant**. Ne jamais la perdre reviendrait à laisser un agent figé
/// indéfiniment — d'où la règle du centre : toute demande retirée sans décision
/// explicite part en `.rejected`.
struct PendingDiffReview: Identifiable {
    /// Identique à `request.id` : une seule identité de bout en bout (protocole → UI).
    let id: UUID
    let request: IDEDiffRequest
    /// Diff pré-calculé à la réception (vs le contenu sur disque) : la vue reste bête.
    let diff: FileDiff
    let origin: DiffReviewOrigin
    /// Horodatage d'arrivée → l'UI affiche l'ancienneté (un agent attend derrière).
    let receivedAt: Date
    let complete: (IDEDiffVerdict) -> Void
}

/// **File d'attente unique des modifications à valider**, quelle que soit leur
/// provenance (agents externes via `IDEHost`, sessions possédées via `SessionStore`).
///
/// Une seule surface de validation dans l'app : la fenêtre flottante s'y abonne, le
/// badge du Dock compte ses éléments. Le centre ne connaît **ni** le réseau **ni**
/// l'UI — il ne fait que garder des demandes et rendre des verdicts.
///
/// Singleton app-level : les demandes sont adossées à des connexions vivantes, elles
/// ne doivent pas disparaître parce qu'une vue a été détruite (invariant du projet :
/// l'état process-backed ne vit jamais dans un `@StateObject`).
///
/// **Thread** : tout se passe sur le thread principal ; les points d'entrée
/// re-marshalent au besoin (les callbacks réseau arrivent sur la file de la connexion).
/// Pas d'annotation de concurrence (le projet n'en utilise aucune).
final class DiffReviewCenter: ObservableObject {

    static let shared = DiffReviewCenter()

    /// Demandes en attente, dans l'ordre d'arrivée (la plus ancienne d'abord : c'est
    /// l'agent qui attend depuis le plus longtemps).
    @Published private(set) var pending: [PendingDiffReview] = []

    private init() {}

    var pendingCount: Int { pending.count }

    // MARK: - Entrée

    /// Nouvelle demande à faire valider. Calcule le diff « disque → contenu proposé »
    /// puis l'ajoute à la file.
    func enqueue(request: IDEDiffRequest,
                 origin: DiffReviewOrigin,
                 complete: @escaping (IDEDiffVerdict) -> Void) {
        onMain {
            // Garde-fou : deux `openDiff` ne partagent jamais d'`id` (UUID local
            // généré à la réception). Si ça arrivait, on refuse le doublon plutôt
            // que d'avoir deux entrées indiscernables dans la file.
            guard !self.pending.contains(where: { $0.id == request.id }) else {
                IDELog.log("revue : demande dupliquée \(request.id) → refusée")
                complete(.rejected)
                return
            }
            let diff = DiffComputer.compute(oldPath: request.oldPath,
                                            newContent: request.newContents)
            self.pending.append(
                PendingDiffReview(id: request.id, request: request, diff: diff,
                                  origin: origin, receivedAt: Date(), complete: complete))
            IDELog.log("revue : +1 (\(origin.label)) +\(diff.addedCount)/−\(diff.removedCount) "
                       + "\(request.oldPath) — \(self.pending.count) en attente")
        }
    }

    // MARK: - Sortie

    /// Décision explicite de l'utilisateur sur une demande.
    func resolve(_ id: UUID, _ verdict: IDEDiffVerdict) {
        onMain {
            guard let item = self.take(id) else { return }
            IDELog.log("revue : verdict \(verdict.logLabel) — \(item.request.oldPath)")
            item.complete(verdict)
            // Filet de sécurité du contrat IDE (T8). L'app n'écrit **jamais** : une
            // acceptation n'existe que si `claude` la matérialise sur disque. Le
            // vérifier est le seul contrôle qui ne suppose rien du protocole — et
            // c'est exactement ce qui manquait quand `FILE_SAVED` à un seul bloc a
            // cessé d'être compris (2.1.205 → 2.1.220) sans que personne ne le voie.
            // Après `complete` : l'agent est bloqué sur cet appel, on le débloque
            // d'abord, on surveille ensuite (la surveillance est asynchrone).
            if case .saved(let content) = verdict {
                IDEContractGuard.shared.verifyAfterAccept(path: item.request.oldPath,
                                                          expected: content)
            }
        }
    }

    /// `claude` a fermé un onglet de diff (`close_tab`) ou tous (`closeAllDiffTabs`,
    /// `matchingTab == nil`) : l'aperçu n'a plus de sens, on le retire **en refusant**
    /// (l'appel bloquant doit recevoir une réponse même si personne n'a décidé).
    func dismiss(matchingTab tab: String?, origin: DiffReviewOrigin) {
        onMain {
            self.rejectAll(where: { item in
                item.origin.kind == origin.kind && (tab == nil || item.request.tabName == tab)
            }, reason: tab == nil ? "tous onglets fermés" : "onglet fermé")
        }
    }

    /// Le client (ou la session) a disparu : plus personne au bout du fil pour lire
    /// notre réponse. On purge en refusant, pour ne pas laisser des demandes mortes
    /// dans la file.
    func dropAll(origin: DiffReviewOrigin) {
        onMain {
            self.rejectAll(where: { $0.origin.kind == origin.kind },
                           reason: "origine disparue")
        }
    }

    // MARK: - Privé

    /// Retire et renvoie la demande `id` (nil si déjà résolue — course possible entre
    /// un clic et un `close_tab`).
    private func take(_ id: UUID) -> PendingDiffReview? {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: i)
    }

    /// Retire toutes les demandes vérifiant `predicate` et les complète en `.rejected`.
    /// On retire **avant** de compléter : la complétion peut réentrer (fermeture de
    /// connexion en cascade) et ne doit pas retomber sur une entrée déjà traitée.
    private func rejectAll(where predicate: (PendingDiffReview) -> Bool, reason: String) {
        let doomed = pending.filter(predicate)
        guard !doomed.isEmpty else { return }
        pending.removeAll(where: predicate)
        IDELog.log("revue : \(doomed.count) demande(s) refusée(s) — \(reason)")
        for item in doomed { item.complete(.rejected) }
    }

    /// Exécute sur le thread principal, **sans re-dispatcher** si on y est déjà :
    /// l'ordre des opérations déclenchées depuis l'UI est ainsi préservé, et un
    /// callback venu d'une file réseau est simplement remarshalé.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
