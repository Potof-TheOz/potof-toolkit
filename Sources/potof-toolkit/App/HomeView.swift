import AppKit
import SwiftUI

/// Page d'accueil du toolkit : la grille des outils, affichée **au lancement**,
/// avant tout choix.
///
/// Deux traits de conception à ne pas « améliorer » par inadvertance :
///
/// 1. **Ce n'est PAS un `Tool`.** La home ne vit pas dans `ToolRegistry` : elle
///    n'a pas de vue d'outil, pas d'entrée dans le sélecteur du header, et le
///    header lui-même n'est pas affiché quand elle est à l'écran (un sélecteur
///    d'outil au-dessus d'une grille d'outils ferait doublon). Elle est un état
///    de `RootView` — celui où `selection == nil`.
/// 2. **Aller-simple.** Une fois un outil choisi, on n'y revient pas : aucun
///    chemin ne remet `selection` à `nil` (voir `RootView`). D'où la mention du
///    menu du header sous la grille : c'est le seul moyen de changer d'outil
///    ensuite, et l'utilisateur ne le découvrira pas ici autrement.
///
/// La vue est purement présentationnelle : elle ne connaît ni le registre ni la
/// sélection, on lui passe les outils et un callback.
struct HomeView: View {
    let tools: [Tool]
    let onSelect: (Tool.ID) -> Void

    /// Carte survolée (surbrillance + légère élévation). `nil` = aucune.
    @State private var hovered: Tool.ID?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        // ScrollView : la fenêtre est redimensionnable sans taille mini, et la
        // grille grandit avec le registre. Sans lui, un outil ajouté ou une
        // fenêtre rétrécie tronquerait des cartes sans recours.
        ScrollView {
            VStack(spacing: 28) {
                identity
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        card(tool, shortcutIndex: index)
                    }
                }
                switchHint
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .bottomTrailing) { versionBadge }
    }

    // MARK: - Identité

    private var identity: some View {
        VStack(spacing: 10) {
            // Icône via `NSApp.applicationIconImage` et **pas** `Bundle.module` :
            // l'accessor SwiftPM déclencherait un `fatalError` en app bundlée
            // (cf. AppDelegate.applyDockIcon). Ici les deux contextes marchent :
            // le `.icns` en bundle, l'icône posée par `applyDockIcon` en dev.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
            Text("Potof Toolkit")
                .font(.system(size: 26, weight: .semibold))
            Text("Choisissez un outil pour commencer.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Carte d'outil

    private func card(_ tool: Tool, shortcutIndex: Int) -> some View {
        let isHovered = hovered == tool.id
        return Button {
            onSelect(tool.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                        .frame(height: 30)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    if let shortcut = shortcutLabel(shortcutIndex) {
                        Text(shortcut)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(tool.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(tool.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered
                          ? Color.accentColor.opacity(0.10)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHovered
                                  ? Color.accentColor.opacity(0.55)
                                  : Color(nsColor: .separatorColor),
                                  lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut(shortcutIndex))
        .onHover { hovering in
            // Pas d'animation sur la sortie du curseur : au clic, la vue est
            // remplacée par l'outil et une animation en cours ferait un flash.
            withAnimation(.easeOut(duration: hovering ? 0.12 : 0)) {
                hovered = hovering ? tool.id : (hovered == tool.id ? nil : hovered)
            }
        }
        .help(tool.subtitle)
        .accessibilityLabel("Ouvrir \(tool.title)")
        .accessibilityHint(tool.subtitle)
    }

    /// Raccourci ⌘1…⌘9 pour les neuf premiers outils. Au-delà : `nil`, donc **aucun**
    /// raccourci — surtout pas un `KeyEquivalent` bidon, qui capterait une frappe.
    ///
    /// ⚠️ Le raccourci vit avec la carte : dans un `LazyVGrid`, une carte encore
    /// hors écran n'est pas instanciée, donc son ⌘N ne répond pas avant qu'on ait
    /// scrollé jusqu'à elle. Sans effet avec quatre outils (tout est visible) ; à
    /// garder en tête si le registre s'allonge.
    private func shortcut(_ index: Int) -> KeyboardShortcut? {
        guard index < 9 else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
    }

    private func shortcutLabel(_ index: Int) -> String? {
        index < 9 ? "⌘\(index + 1)" : nil
    }

    // MARK: - Pied

    /// La home ne revient pas : dire ici où se change l'outil ensuite.
    private var switchHint: some View {
        Text("Vous pourrez changer d'outil à tout moment depuis le menu en haut à gauche.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    /// Version marketing, seulement en app bundlée : en dev (`swift run`) il n'y a
    /// pas d'Info.plist, donc pas de clé — on n'affiche rien plutôt qu'un « v? ».
    @ViewBuilder
    private var versionBadge: some View {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text("v\(short)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .accessibilityLabel("Version \(short)")
        }
    }
}
