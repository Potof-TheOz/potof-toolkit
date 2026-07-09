import Foundation

/// Une session iTerm2 ouverte, telle que rapportée en direct par AppleScript.
/// Dérivée à la volée (jamais persistée) : la liste reflète l'état réel d'iTerm2.
struct ITermSession: Identifiable, Hashable {
    let id: String     // identifiant unique de session iTerm2
    let path: String   // répertoire courant (variable « path »)
    let name: String   // titre de la session/onglet
}
