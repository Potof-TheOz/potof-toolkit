import SwiftUI

/// Décrit un outil du toolkit (métadonnées + vue).
///
/// Pour ajouter un nouvel outil :
///   1. Créer sa vue SwiftUI dans `Tools/<MonOutil>/`.
///   2. Ajouter une entrée `Tool(...)` dans `ToolRegistry.all`.
/// Rien d'autre à câbler : la barre latérale et le routage sont automatiques.
struct Tool: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// Nom de SF Symbol affiché dans la barre latérale.
    let icon: String
    /// Fabrique la vue de l'outil (effacée en AnyView pour un registre hétérogène).
    let makeView: () -> AnyView

    init(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder view: @escaping () -> some View
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.makeView = { AnyView(view()) }
    }
}
