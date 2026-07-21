import SwiftUI
import AppKit

/// Outil « Git Stuffs ».
///
/// Disposition en deux volets (`HSplitView`, jamais `NavigationSplitView`) :
/// - **Sidebar gauche** : liste filtrable des repos git découverts sur le poste.
/// - **Centre** : sur le repo sélectionné, la branche courante + le graphe de
///   commits, et l'accès au rebase interactif.
///
/// v1 : la seule action git offerte est le **rebase interactif** (réel, encadré).
struct GitStuffsView: View {
    /// Id de l'outil (référencé par `ToolRegistry`).
    static let toolID: Tool.ID = "git-stuffs"

    @StateObject private var repos = RepoStore()
    @State private var selection: GitRepo.ID?
    @State private var searchText = ""
    /// Le scan de `$HOME` n'est automatique qu'au tout 1er lancement ; ensuite on lit
    /// le cache (le bouton Rafraîchir relance un scan à la demande).
    @AppStorage("gitStuffs.didScanOnce") private var didScanOnce = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            center
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 500)
        .onAppear {
            if !didScanOnce {
                didScanOnce = true
                repos.scan()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)
            Divider()
            repoList
            Divider()
            sidebarFooter
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            TextField("Filtrer par nom ou chemin", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Effacer le filtre")
                .accessibilityLabel("Effacer le filtre")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var repoList: some View {
        if repos.repos.isEmpty {
            emptyRepos
        } else if displayedRepos.isEmpty {
            emptyMessage(icon: "magnifyingglass", text: "Aucun repo pour « \(searchText) ».")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(displayedRepos) { repo in
                        RepoRow(repo: repo, isSelected: repo.id == selection) {
                            selection = repo.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyRepos: some View {
        if repos.isScanning {
            emptyMessage(icon: "hourglass", text: "Recherche des repos…")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun repo git trouvé")
                    .font(.system(size: 12, weight: .medium))
                Button { repos.scan() } label: { Text("Lancer un scan…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func emptyMessage(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if repos.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scan… \(repos.foundSoFar) repo\(repos.foundSoFar > 1 ? "s" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text("\(repos.repos.count) repo\(repos.repos.count > 1 ? "s" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Button { repos.scan() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(repos.isScanning)
            .help("Re-scanner le disque à la recherche de repos (⌘R)")
            .accessibilityLabel("Rafraîchir la liste des repos")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Centre

    @ViewBuilder
    private var center: some View {
        if let repo = selectedRepo {
            RepoDetailView(repo: repo)
                .id(repo.id)     // état frais par repo (recharge branche + commits)
        } else {
            centerEmptyState
        }
    }

    private var centerEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Aucun repo sélectionné")
                .font(.title3.weight(.semibold))
            Text("Choisissez un repo dans la barre latérale pour voir sa branche et ses commits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(.background)
    }

    // MARK: - Données dérivées

    private var selectedRepo: GitRepo? {
        repos.repos.first { $0.id == selection }
    }

    private var displayedRepos: [GitRepo] {
        guard !searchText.isEmpty else { return repos.repos }
        return repos.repos.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Ligne de repo

private struct RepoRow: View {
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(repo.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
