import SwiftUI

/// Disposition d'affichage des diffs de Git Stuffs. Préférence **globale** persistée
/// (`@AppStorage("gitStuffs.diffLayoutMode")`), partagée par les deux vues de diff
/// (commit en lecture seule et copie de travail interactive).
enum DiffLayoutMode: String {
    case unified
    case sideBySide
}

/// Sélecteur d'icônes (style segmenté) unifié / côte à côte, placé en haut à droite
/// de l'en-tête des vues de diff. Chaque bouton porte son `.help` +
/// `.accessibilityLabel` (convention projet : tout contrôle en icône a une infobulle).
///
/// Contrôle maison plutôt qu'un `Picker(.segmented)` : ce dernier n'autorise pas
/// d'infobulle par segment.
struct DiffLayoutToggle: View {
    @Binding var mode: DiffLayoutMode

    var body: some View {
        HStack(spacing: 0) {
            segment(.unified, image: "list.bullet", label: "Vue unifiée")
            segment(.sideBySide, image: "rectangle.split.2x1", label: "Vue côte à côte")
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
    }

    private func segment(_ value: DiffLayoutMode, image: String, label: String) -> some View {
        let isOn = mode == value
        return Button { mode = value } label: {
            Image(systemName: image)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 20)
                .background(isOn ? Color.accentColor.opacity(0.22) : Color.clear)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
