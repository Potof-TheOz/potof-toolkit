import SwiftUI
import AppKit

/// Outil « Git Stuffs ».
///
/// Modèle **GitHub Desktop** : pas de barre latérale permanente de repos. Le repo courant
/// se choisit via un **menu déroulant** en haut (`RepoPicker`) ; le centre affiche pour ce
/// repo un espace de travail à deux onglets **Modifications / Historique** (`RepoDetailView`).
struct GitStuffsView: View {
    /// Id de l'outil (référencé par `ToolRegistry`).
    static let toolID: Tool.ID = "git-stuffs"

    @StateObject private var repos = RepoStore()
    @State private var selection: GitRepo.ID?
    /// Le scan de `$HOME` n'est automatique qu'au tout 1er lancement ; ensuite on lit le
    /// cache (le bouton Rafraîchir du picker relance un scan à la demande).
    @AppStorage("gitStuffs.didScanOnce") private var didScanOnce = false

    var body: some View {
        Group {
            if let repo = selectedRepo {
                RepoDetailView(
                    repo: repo,
                    repos: repos.repos,
                    isScanning: repos.isScanning,
                    onRescan: { repos.scan() },
                    onSelectRepo: { selection = $0.id }
                )
                .id(repo.id)     // état frais par repo (recharge branche + commits + statut)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 820, minHeight: 500)
        .onAppear {
            if !didScanOnce {
                didScanOnce = true
                repos.scan()
            }
            selectFirstIfNeeded()
        }
        .onChange(of: repos.repos) { _ in selectFirstIfNeeded() }
    }

    // MARK: - Sélection

    /// Sélectionne le premier repo si rien n'est choisi (ou si la sélection a disparu).
    private func selectFirstIfNeeded() {
        if selection == nil || !repos.repos.contains(where: { $0.id == selection }) {
            selection = repos.repos.first?.id
        }
    }

    private var selectedRepo: GitRepo? {
        repos.repos.first { $0.id == selection }
    }

    // MARK: - État vide (aucun repo)

    @ViewBuilder
    private var emptyState: some View {
        if repos.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Recherche des repos… \(repos.foundSoFar)")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun repo git trouvé")
                    .font(.title3.weight(.semibold))
                Text("Lance un scan de ton dossier personnel pour découvrir les repos.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button { repos.scan() } label: { Text("Lancer un scan…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(.background)
        }
    }
}

// MARK: - Sélecteur de repo (menu déroulant filtrable)

/// Bouton « repo courant ▾ » ouvrant un popover : champ de recherche + liste filtrable des
/// repos + pied (compte + re-scan). Remplace l'ancienne barre latérale permanente.
struct RepoPicker: View {
    let repos: [GitRepo]
    let currentID: GitRepo.ID?
    let isScanning: Bool
    let onRescan: () -> Void
    let onSelect: (GitRepo) -> Void

    @State private var isOpen = false
    @State private var search = ""

    private var current: GitRepo? { repos.first { $0.id == currentID } }
    private var filtered: [GitRepo] {
        guard !search.isEmpty else { return repos }
        return repos.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(current?.name ?? "Choisir un repo")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .help("Changer de repo")
        .accessibilityLabel("Sélecteur de repo")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            popoverContent.frame(width: 320, height: 400)
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    .accessibilityHidden(true)
                TextField("Filtrer par nom ou chemin", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(8)
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(repos.isEmpty ? "Aucun repo" : "Aucun repo pour « \(search) »")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { repo in
                            RepoRow(repo: repo, isSelected: repo.id == currentID) {
                                onSelect(repo)
                                isOpen = false
                            }
                        }
                    }
                    .padding(8)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("\(repos.count) repo\(repos.count > 1 ? "s" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button { onRescan() } label: {
                    if isScanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).disabled(isScanning)
                .help("Re-scanner le disque").accessibilityLabel("Rafraîchir la liste des repos")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

// MARK: - Ligne de repo (liste du picker)

struct RepoRow: View {
    let repo: GitRepo
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(repo.displayPath)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(repo.path)
    }
}
