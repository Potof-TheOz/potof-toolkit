import SwiftUI

/// Rendu **partagé** d'une ligne de diff : deux gouttières de numéros (ancien /
/// nouveau), un marqueur (`+` / `−` / espace) puis le texte. Le fond signale
/// l'ajout / la suppression.
///
/// Consomme le `DiffLine` produit par `DiffComputer` (voir `Core/Diff/DiffModel`).
/// Mutualisé entre l'aperçu des diffs Claude (`DiffOverlayView`, pont IDE) et
/// l'aperçu des commits de Git Stuffs (`CommitDiffView`).
struct DiffLineRow: View {
    let line: DiffLine
    /// `true` (défaut) : le texte revient à la ligne (aperçu à largeur fixe, pont IDE).
    /// `false` : ligne unique de largeur naturelle → à mettre dans un ScrollView
    /// horizontal (aperçu des commits Git Stuffs, où le code ne doit pas être serré).
    var wraps: Bool = true
    /// `true` : une seule gouttière de numéro (nouveau, ou ancien pour un retrait) pour
    /// gagner de la place à gauche ; `false` (défaut) : deux gouttières ancien + nouveau.
    var compactGutter: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if compactGutter {
                gutter(line.newNumber ?? line.oldNumber)
            } else {
                gutter(line.oldNumber)
                gutter(line.newNumber)
            }

            Text(marker)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(markerColor)

            // Le texte n'est PAS « trimmé » : espaces / indentation significatifs conservés.
            lineText
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    @ViewBuilder
    private var lineText: some View {
        let text = Text(line.text.isEmpty ? " " : line.text).foregroundStyle(.primary)
        if wraps {
            text
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 12)
        } else {
            text
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 6)
            .accessibilityHidden(true)
    }

    private var marker: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added:   return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added:   return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return Color.clear
        }
    }
}
