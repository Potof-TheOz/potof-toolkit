import SwiftUI
import AppKit

/// Outil « Git Stuffs ».
///
/// Modèle **GitHub Desktop**, désormais **worktree-aware** et **centré favoris** : pas de barre
/// latérale permanente de repos. Le worktree courant se choisit via un **menu déroulant** en haut
/// (`ProjectPicker`, défini dans `Projects/ProjectPicker.swift`) ; le centre affiche pour ce
/// worktree un espace de travail à deux onglets **Modifications / Historique** (`RepoDetailView`).
///
/// L'unité n'est plus un dossier de repo mais un **worktree** appartenant à un **projet git**
/// (`--git-common-dir`). L'état vit dans un `ProjectStore` (favoris + worktrees paresseux) qui
/// n'est **pas** process-backed → `@StateObject` est correct ici (contrairement aux stores de
/// sessions/scripts qui, eux, doivent rester des singletons).
struct GitStuffsView: View {
    /// Id de l'outil (référencé par `ToolRegistry`).
    static let toolID: Tool.ID = "git-stuffs"

    /// Store worktree-aware. NON process-backed → `@StateObject` (comme l'ancien `RepoStore`).
    @StateObject private var store = ProjectStore()
    /// Worktree courant (identité = chemin absolu).
    @State private var selected: Worktree?
    /// Le scan de `$HOME` n'est automatique qu'au tout 1er lancement ; ensuite on lit le
    /// cache (le picker relance un scan à la demande).
    @AppStorage("gitStuffs.didScanOnce") private var didScanOnce = false

    var body: some View {
        VStack(spacing: 0) {
            // Bandeau transitoire (ex. « worktree disparu ») au-dessus de tout : visible aussi
            // bien en détail qu'en état vide.
            if let message = store.transientMessage {
                transientBanner(message)
                Divider()
            }
            Group {
                if let worktree = selected {
                    RepoDetailView(worktree: worktree, projects: store, onSelect: select)
                        // État frais par worktree : recharge branche + commits + copie de travail.
                        // Invariant du projet — l'état process-backed du détail est recréé par worktree.
                        .id(worktree.id)
                } else {
                    emptyState
                }
            }
        }
        .frame(minWidth: 820, minHeight: 500)
        .onAppear {
            if !didScanOnce {
                didScanOnce = true
                store.scan()
            }
            // Résout de façon asynchrone le dernier worktree ouvert (ou un repli favori).
            store.resolveInitialSelection { w in if let w { select(w) } }
        }
        // Retour au premier plan : rafraîchit favoris + projet courant. Si le worktree courant
        // a disparu, `refreshOnForeground` renvoie un worktree de repli — on bascule dessus SANS
        // passer par `select()` (qui effacerait le message « worktree disparu » à afficher).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshOnForeground(current: selected) { fallback in
                guard let fallback else { return }
                selected = fallback
                store.rememberSelection(fallback)
            }
        }
    }

    // MARK: - Sélection

    /// Sélectionne un worktree, mémorise le choix (dernier ouvert) et efface tout message
    /// transitoire résiduel (ex. bandeau « worktree disparu »).
    private func select(_ worktree: Worktree) {
        selected = worktree
        store.rememberSelection(worktree)
        store.transientMessage = nil
    }

    // MARK: - État vide (aucun worktree sélectionné)

    @ViewBuilder
    private var emptyState: some View {
        if store.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Recherche des repos… \(store.foundSoFar)")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun favori épinglé")
                    .font(.title3.weight(.semibold))
                Text("Ouvre le sélecteur pour épingler tes repos, ou ajoute-en un.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                // Point d'entrée unique pour choisir/épingler un projet. Sans favori, le popup
                // ouvre « Tous les projets » déplié automatiquement.
                ProjectPicker(store: store, current: nil, onSelect: select)

                Button { store.scan() } label: { Text("Lancer un scan…") }
                    .help("Re-scanner le disque pour découvrir les repos")
                    .accessibilityLabel("Lancer un scan des repos")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(.background)
        }
    }

    /// Bandeau discret pour un message transitoire (ex. worktree disparu), avec fermeture.
    @ViewBuilder
    private func transientBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary).font(.system(size: 12))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { store.transientMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Fermer le message")
            .accessibilityLabel("Fermer le message")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
