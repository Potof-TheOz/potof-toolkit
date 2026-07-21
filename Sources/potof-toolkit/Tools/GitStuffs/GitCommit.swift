import Foundation

/// Un commit de la branche courante, tel que listé par `git log`.
struct GitCommit: Identifiable, Hashable {
    /// Hash complet = identité stable.
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    /// Date relative déjà formatée par git (`%ar`, ex. « il y a 2 jours »).
    let relativeDate: String
    /// Commit de fusion (plus d'un parent) ? Le rebase interactif « aplatit » les
    /// merges → on interdit de rebaser une plage qui en contient un.
    let isMerge: Bool

    var id: String { hash }
}
