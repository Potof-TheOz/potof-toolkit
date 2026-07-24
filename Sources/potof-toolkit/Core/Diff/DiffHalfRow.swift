import SwiftUI

/// Une **moitié** de ligne du rendu côte à côte : une gouttière de numéro + le
/// texte, avec le fond ajout / suppression. `line == nil` (côté sans contrepartie,
/// ex. l'ancien d'un ajout pur) rend une cellule neutre légèrement grisée.
///
/// Pourquoi pas `DiffLineRow(compactGutter:)` : en compact il affiche
/// `newNumber ?? oldNumber`, faux pour le côté *ancien* d'une ligne de contexte
/// (dont les numéros ancien/nouveau diffèrent). Ici `side` choisit le bon numéro.
/// Pas de marqueur `+`/`−` : la couleur et la colonne suffisent (style WebStorm).
struct DiffHalfRow: View {
    enum Side { case old, new }
    let line: DiffLine?
    let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(number)
            lineText
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var number: Int? {
        guard let line else { return nil }
        return side == .old ? line.oldNumber : line.newNumber
    }

    @ViewBuilder
    private var lineText: some View {
        // Espaces / indentation significatifs conservés ; `nil` → cellule vide.
        let content = line?.text
        Text((content?.isEmpty == false ? content! : " "))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 12)
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
    }

    private var background: Color {
        guard let line else { return Color.primary.opacity(0.035) }  // remplissage neutre
        switch line.kind {
        case .added:   return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }
}
