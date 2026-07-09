import SwiftUI
import AppKit

/// Aperçu modal d'une **modification proposée par Claude** (outil MCP `openDiff`).
///
/// Cette vue **ne touche jamais au disque** (cf. `IDEBridge`) : elle se contente de
/// présenter le diff « avant / après » (calculé en amont par `DiffModel`) puis de
/// remonter le verdict de l'utilisateur via `onAccept` / `onReject`. C'est ensuite
/// `claude`, côté CLI, qui écrit (accept) ou laisse le fichier intact (reject).
///
/// **Présentation** : un panneau plein cadre posé **au-dessus du terminal**. Le fond
/// `.regularMaterial` masque (en le floutant) le terminal derrière et capte tous les
/// clics — on obtient l'impression d'une feuille modale native. Une « carte »
/// centrale (coins arrondis, fine bordure, ombre discrète) porte l'en-tête, le corps
/// scrollable et le pied d'action.
struct DiffOverlayView: View {
    let request: IDEDiffRequest
    let diff: FileDiff
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        ZStack {
            // Voile plein cadre : floute + masque le terminal et intercepte les clics
            // (rien ne « traverse » vers la vue du dessous pendant la validation).
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            card
                // Largeur bornée pour rester lisible sur grand écran, hauteur libre
                // pour remplir le cadre ; le padding dégage le voile autour.
                .frame(maxWidth: 900, maxHeight: .infinity)
                .padding(24)
        }
    }

    // MARK: - Carte

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modification proposée par Claude")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    // Nom de fichier = dernier composant du chemin « avant ».
                    Text(fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(request.oldPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)
                badges
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    /// Compteurs colorés + éventuel marqueur « nouveau fichier ».
    private var badges: some View {
        HStack(spacing: 6) {
            if diff.isNewFile {
                badge(text: "Nouveau fichier", systemImage: "sparkles", color: .accentColor)
                    .accessibilityLabel("Nouveau fichier")
            }
            badge(text: "+\(diff.addedCount)", color: .green)
                .accessibilityLabel("\(diff.addedCount) lignes ajoutées")
            badge(text: "−\(diff.removedCount)", color: .red)
                .accessibilityLabel("\(diff.removedCount) lignes supprimées")
        }
    }

    private func badge(text: String, systemImage: String? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Corps

    @ViewBuilder
    private var content: some View {
        if diff.isBinary {
            // Cas binaire : pas de diff textuel possible, mais on conserve le pied
            // d'action pour laisser l'utilisateur voter quand même.
            emptyState(icon: "doc.badge.ellipsis",
                       text: "Fichier binaire — aperçu indisponible")
        } else if diff.lines.isEmpty {
            // Robustesse : diff vide (fichier identique / cas limite). On n'affiche
            // pas une liste vide muette.
            emptyState(icon: "equal.circle",
                       text: "Aucune différence à afficher.")
        } else {
            diffScroll
        }
    }

    /// Liste des lignes du diff. `LazyVStack` (et non `VStack`) : seules les lignes
    /// visibles sont réellement construites → reste fluide sur de très gros fichiers.
    private var diffScroll: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines) { line in
                    DiffLineRow(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Pied d'action

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            // Refuser : rôle discret + Échap. Laisse le fichier intact côté CLI.
            Button(action: onReject) {
                Text("Refuser")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("Refuser — le fichier reste inchangé")
            .accessibilityLabel("Refuser — le fichier reste inchangé")

            // Accepter : action par défaut (Entrée). Claude écrira ensuite le fichier.
            Button(action: onAccept) {
                Text("Accepter")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .help("Accepter et laisser Claude écrire le fichier")
            .accessibilityLabel("Accepter et laisser Claude écrire le fichier")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Données dérivées

    private var fileName: String {
        (request.oldPath as NSString).lastPathComponent
    }
}

// MARK: - Ligne de diff

/// Une ligne du diff : deux gouttières de numéros (ancien / nouveau), un marqueur
/// (`+` / `−` / espace) puis le texte. Le fond signale l'ajout / la suppression.
private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldNumber)
            gutter(line.newNumber)

            Text(marker)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(markerColor)

            // Le texte n'est PAS « trimmé » : espaces / indentation significatifs
            // conservés. On autorise le retour à la ligne (wrap) plutôt que de
            // masquer le dépassement, pour ne rien cacher du contenu proposé.
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
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
