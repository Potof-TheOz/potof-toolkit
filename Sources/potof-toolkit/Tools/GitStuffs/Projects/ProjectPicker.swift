import SwiftUI
import AppKit
import Foundation

/// Sélecteur de **projet git** (remplace `RepoPicker`). Liste **plate** de projets : le choix
/// du worktree se fait ensuite dans un second menu (`WorktreePicker`) de la barre du haut.
///
/// Reprend le style de l'ancien `RepoPicker` : bouton « projet ▾ » ouvrant un popover 320×400
/// avec champ de recherche, lignes arrondies au survol et pied (compte + re-scan). Nouveautés :
/// - l'unité est un **projet** (`--git-common-dir`), qui peut regrouper plusieurs worktrees
///   (indiqués par un badge « ⑂N » ; on les choisit via le `WorktreePicker`) ;
/// - **deux sections** quand la recherche est vide (Favoris + « Tous les projets ») ;
/// - **épinglage** en favori par ligne (★) ;
/// - **« Ajouter un repo… »** via `NSOpenPanel`.
struct ProjectPicker: View {
    @ObservedObject var store: ProjectStore
    /// Worktree actuellement ouvert (nil si aucun).
    let current: Worktree?
    /// Sélectionner un worktree → ferme le popover.
    let onSelect: (Worktree) -> Void

    @State private var isOpen = false
    @State private var search = ""
    /// État de dépliage de « Tous les projets » (réglé à l'ouverture selon les favoris).
    @State private var isAllExpanded = false
    /// Erreur de l'ajout d'un repo (affichée en rouge dans le popover).
    @State private var addError: String?

    // MARK: - Bouton déclencheur

    /// Nom du projet propriétaire du worktree courant (pour le libellé du bouton).
    private var currentProjectName: String? {
        guard let current else { return nil }
        return store.project(containing: current)?.name ?? current.folderName
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(currentProjectName ?? "Choisir un repo")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .help("Changer de projet")
        .accessibilityLabel("Sélecteur de projet, actuel : \(currentProjectName ?? "aucun")")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            popoverContent.frame(width: 320, height: 400)
        }
    }

    // MARK: - Contenu du popover

    private var popoverContent: some View {
        VStack(spacing: 0) {
            // Champ de recherche.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    .accessibilityHidden(true)
                TextField("Filtrer par nom ou chemin", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(8)
            Divider()

            // Corps : sections (recherche vide) ou liste plate (recherche active).
            Group {
                if search.isEmpty {
                    reposMode
                } else {
                    searchMode
                }
            }

            // Erreur d'ajout (rouge), le cas échéant.
            if let addError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(addError).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .onAppear {
            // Onboarding : « Tous les projets » déplié par défaut tant qu'aucun favori.
            isAllExpanded = store.favorites.isEmpty
        }
    }

    // MARK: - Mode REPOS (recherche vide) : deux sections

    private var reposMode: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Section « Favoris ».
                sectionHeader("Favoris")
                if store.favoriteProjects.isEmpty {
                    Text("Aucun favori épinglé — épingle un projet ci-dessous avec ★")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(store.favoriteProjects) { project in
                            ProjectRow(store: store, project: project, current: current, onSelect: handleSelect)
                        }
                    }
                }

                // Section « Tous les projets (N) » — repliable.
                DisclosureGroup(isExpanded: $isAllExpanded) {
                    LazyVStack(spacing: 2) {
                        ForEach(store.allProjects) { project in
                            ProjectRow(store: store, project: project, current: current, onSelect: handleSelect)
                        }
                    }
                } label: {
                    Text("Tous les projets (\(store.allProjects.count))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .help("Afficher tous les projets détectés")
                .accessibilityLabel("Tous les projets, \(store.allProjects.count)")
            }
            .padding(8)
        }
    }

    // MARK: - Mode RECHERCHE (recherche non vide) : liste plate

    /// Projets dont le nom OU le chemin du common-dir matche la recherche (jamais les
    /// branches). Ordre : favoris d'abord, puis le reste, chacun trié alpha par nom.
    private var searchResults: [GitProject] {
        let matched = store.allProjects.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.commonDir.localizedCaseInsensitiveContains(search)
        }
        func alpha(_ a: GitProject, _ b: GitProject) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let favs = matched.filter { store.isFavorite($0) }.sorted(by: alpha)
        let rest = matched.filter { !store.isFavorite($0) }.sorted(by: alpha)
        return favs + rest
    }

    @ViewBuilder
    private var searchMode: some View {
        if searchResults.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun projet pour « \(search) »")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(searchResults) { project in
                        ProjectRow(store: store, project: project, current: current, onSelect: handleSelect)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Pied

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(store.allProjects.count) projet\(store.allProjects.count > 1 ? "s" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { presentAddPanel() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Ajouter un repo…").accessibilityLabel("Ajouter un repo")

            Button { store.scan() } label: {
                if store.isScanning { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain).disabled(store.isScanning)
            .help("Re-scanner le disque").accessibilityLabel("Rafraîchir la liste des projets")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func handleSelect(_ worktree: Worktree) {
        onSelect(worktree)
        isOpen = false
    }

    /// Ouvre un `NSOpenPanel` (dossiers uniquement) et délègue au store. La complétion arrive
    /// déjà sur le thread principal ; succès → sélection + fermeture, échec → erreur rouge.
    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        panel.message = "Choisis un dossier de repo git."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addProject(at: url) { result in
            switch result {
            case .success(let worktree):
                addError = nil
                onSelect(worktree)
                isOpen = false
            case .failure(let error):
                addError = error.message
                isOpen = true   // le panneau modal a pu refermer le popover : on le rouvre.
            }
        }
    }
}

// MARK: - Ligne de projet

/// Une ligne de projet dans le sélecteur (liste **plate** — le choix du worktree se fait
/// ensuite via le `WorktreePicker` de la barre du haut). Cliquer ouvre le worktree **principal**
/// du projet. Un badge « ⑂N » signale les projets multi-worktrees. Un projet dangling (aucun
/// worktree existant) est grisé et non sélectionnable ; l'étoile reste active pour le désépingler.
private struct ProjectRow: View {
    @ObservedObject var store: ProjectStore
    let project: GitProject
    let current: Worktree?
    let onSelect: (Worktree) -> Void

    @State private var hovering = false

    /// Worktrees ouvrables chargés (exclut le bare).
    private var checkouts: [Worktree] { store.worktrees(for: project).filter { !$0.isBare } }
    /// Chargé mais aucun worktree ouvrable → cas dangling (favori dont tout a disparu).
    private var isDangling: Bool { store.isLoaded(project) && checkouts.isEmpty }
    /// Le worktree courant appartient-il à ce projet ?
    private var containsCurrent: Bool {
        guard let current else { return false }
        return store.worktrees(for: project).contains { $0.id == current.id }
    }
    /// Chemin abrégé du dossier parent du common-dir (sous-titre du projet).
    private var parentPath: String {
        (URL(fileURLWithPath: project.commonDir).deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    var body: some View {
        Group {
            if isDangling { danglingRow } else { selectableRow }
        }
        .onAppear { store.ensureLoaded(project) }   // paresseux : nécessaire pour connaître le principal
    }

    private var selectableRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 13))
                .foregroundStyle(containsCurrent ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(parentPath)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if checkouts.count > 1 {
                // Indice : plusieurs worktrees (choisis via le sélecteur de worktree en haut).
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text("\(checkouts.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help("\(checkouts.count) worktrees")
                .accessibilityLabel("\(checkouts.count) worktrees")
            }
            Spacer(minLength: 4)
            starButton
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(containsCurrent ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.ensureLoaded(project)
            if let primary = store.primaryWorktree(for: project) { onSelect(primary) }
        }
        .onHover { hovering = $0 }
        .help(project.commonDir)
    }

    /// Étoile d'épinglage. `Button` → capte son propre tap (n'entraîne PAS la sélection).
    private var starButton: some View {
        Button {
            store.toggleFavorite(project)
        } label: {
            Image(systemName: store.isFavorite(project) ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(store.isFavorite(project) ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("Ajouter/Retirer des favoris")
        .accessibilityLabel(store.isFavorite(project) ? "Retirer des favoris" : "Ajouter aux favoris")
    }

    /// Cas dangling : favori dont plus aucun worktree n'existe sur le disque. Grisé, non
    /// sélectionnable — l'étoile reste active pour pouvoir le désépingler.
    private var danglingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("aucun worktree")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            starButton
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .opacity(0.6)
        .help("\(project.commonDir) — aucun worktree existant")
    }
}
