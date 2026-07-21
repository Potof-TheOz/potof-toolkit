import SwiftUI

/// Centre de l'outil pour un repo sélectionné : barre (branche + rebase), puis
/// graphe de commits de la branche courante. Recréé par repo (`.id(repo.id)`).
struct RepoDetailView: View {
    let repo: GitRepo
    @StateObject private var detail: RepoDetail
    /// Contrôleur du rebase courant. Présenté via `.sheet(item:)` : non nil ⇒ feuille
    /// ouverte, nil ⇒ fermée (garantit un contenu rendu, pas de feuille vide).
    @State private var rebase: RebaseController?
    /// Commit dont on affiche le diff (feuille lecture seule), ou nil.
    @State private var diffTarget: CommitDiffTarget?

    init(repo: GitRepo) {
        self.repo = repo
        _detail = StateObject(wrappedValue: RepoDetail(repo: repo.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let controller = rebase {
                // Rebase présenté EN PLACE (pas en feuille) : remplit la zone centrale
                // et se redimensionne avec la fenêtre. `onClose` revient au graphe.
                RebasePanelView(controller: controller, onClose: {
                    rebase = nil
                    detail.load()      // l'historique a pu changer : on recharge le graphe
                })
            } else {
                if detail.rebaseInProgress {
                    inProgressBanner
                    Divider()
                }
                content
            }
        }
        .background(.background)
        .onAppear(perform: detail.load)
    }

    /// Construit la cible de diff pour un commit du repo courant.
    private func diffTarget(for commit: GitCommit) -> CommitDiffTarget {
        CommitDiffTarget(repo: repo.url, hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject)
    }

    // MARK: - Barre supérieure

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Image(systemName: detail.isDetached ? "arrow.triangle.branch" : "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text(detail.branch.isEmpty ? "…" : detail.branch)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(detail.isDetached ? Color.orange : .secondary)
                }
            }
            if let up = detail.upstream {
                Label(up, systemImage: "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Branche amont : \(up)")
            }
            Spacer(minLength: 12)
            Button { detail.load() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Recharger la branche et les commits")
            .accessibilityLabel("Recharger")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var inProgressBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Un rebase est déjà en cours dans ce repo.")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Button("Reprendre le contrôle") {
                let controller = RebaseController(repo: repo.url, commits: detail.commits, upstream: detail.upstream)
                controller.attachToInProgress()
                rebase = controller
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if detail.isLoading && detail.commits.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Lecture de l'historique…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = detail.loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24)).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if detail.commits.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun commit sur cette branche.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            graphArea
        }
    }

    /// Graphe à gauche, panneau de diff à droite (ouvert au clic, fermable).
    private var graphArea: some View {
        HSplitView {
            // Diff fermé → le graphe remplit tout ; diff ouvert → graphe borné pour
            // laisser la majorité de la largeur au diff (lecture du code).
            commitGraph
                .frame(minWidth: 340, maxWidth: diffTarget == nil ? .infinity : 560)
            if let target = diffTarget {
                CommitDiffView(target: target, onClose: { diffTarget = nil })
                    // Identité par commit : cliquer un autre commit recrée la vue
                    // (état neuf + rechargement), sinon l'ancien diff resterait affiché.
                    .id(target.id)
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
        }
    }

    private var commitGraph: some View {
        let currentColor = branchColor(detail.branch)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Clic : voir le diff · clic droit : rebase interactif.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                // Légende des couleurs du graphe (branche courante / base).
                legendItem(color: currentColor, label: detail.branch)
                if let base = detail.baseBranchName {
                    legendItem(color: .secondary, label: base)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(detail.commits.enumerated()), id: \.element.id) { index, commit in
                        if index == forkBoundaryIndex {
                            forkDivider
                        }
                        let isOwn = detail.branchOwnHashes.contains(commit.hash)
                        CommitRow(
                            commit: commit,
                            isFirst: index == 0,
                            isLast: index == detail.commits.count - 1,
                            isPushed: detail.pushedHashes.contains(commit.hash),
                            dotColor: isOwn ? currentColor : .secondary,
                            isSelected: diffTarget?.hash == commit.hash,
                            onSelect: { diffTarget = diffTarget(for: commit) }
                        )
                        .contextMenu { commitMenu(index: index) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// Séparateur marquant le point de création de la branche (bascule vers la base).
    private var forkDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text("Création de « \(detail.branch) »" + (detail.baseBranchName.map { " · base : \($0)" } ?? ""))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("Couleur du graphe pour « \(label) »")
    }

    /// Menu contextuel d'un commit : rebase interactif depuis ce commit (inclut ce
    /// commit et tous les plus récents). Le menu **ouvre toujours** le panneau (sauf
    /// rebase déjà en cours) ; les garde-fous (arbre propre, fusions, etc.) sont
    /// affichés et appliqués DANS le panneau, pas ici — ainsi le rebase se déclenche
    /// et l'utilisateur voit ce qui bloque.
    @ViewBuilder
    private func commitMenu(index: Int) -> some View {
        let commit = detail.commits[index]
        // Toujours disponible (lecture seule), quel que soit l'état du rebase.
        Button {
            diffTarget = diffTarget(for: commit)
        } label: {
            Label("Voir les modifications (diff)", systemImage: "doc.text.magnifyingglass")
        }
        Divider()
        if detail.rebaseInProgress {
            Text("Un rebase est déjà en cours — utilisez la bannière ci-dessus")
        } else if !detail.branchOwnHashes.contains(commit.hash) {
            Text("Commit antérieur à la création de la branche — rebase interdit")
        } else {
            Button {
                rebase = RebaseController(
                    repo: repo.url,
                    commits: detail.commits,
                    upstream: detail.upstream,
                    initialCount: index + 1,
                    rebaseableCount: branchOwnLeadingCount
                )
            } label: {
                Label("Rebase interactif depuis ce commit", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    /// Nombre de commits en tête (depuis HEAD) propres à la branche, avant d'atteindre le
    /// point de création. Borne la plage rebasable (jamais un commit partagé avec la base).
    private var branchOwnLeadingCount: Int {
        var count = 0
        for commit in detail.commits {
            if detail.branchOwnHashes.contains(commit.hash) { count += 1 } else { break }
        }
        return count
    }

    /// Index du 1er commit de la branche de base (frontière de création), ou `nil` si
    /// non pertinent (pas de base détectée, ou tous les commits sont propres à la branche).
    private var forkBoundaryIndex: Int? {
        guard detail.baseBranchName != nil else { return nil }
        let k = branchOwnLeadingCount
        return (k > 0 && k < detail.commits.count) ? k : nil
    }

    /// Couleur stable dérivée d'un nom de branche (déterministe, indépendante du hash
    /// aléatoire de String) → chaque branche a sa teinte dans le graphe.
    private func branchColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint, .cyan]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette.isEmpty ? .accentColor : palette[sum % palette.count]
    }
}

// MARK: - Ligne de commit (graphe linéaire)

private struct CommitRow: View {
    let commit: GitCommit
    let isFirst: Bool
    let isLast: Bool
    /// Commit déjà présent sur l'amont (affiché à titre indicatif : le rebaser
    /// impliquera un force-push).
    let isPushed: Bool
    /// Couleur de la pastille/trait = couleur de la branche (ou gris pour la base).
    let dotColor: Color
    /// Ligne sélectionnée (diff affiché dans le panneau de droite).
    let isSelected: Bool
    /// Clic sur la ligne → ouvre le diff dans le panneau de droite.
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            graphGutter
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    if commit.isMerge {
                        Text("merge")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.20)))
                            .help("Commit de fusion")
                    }
                }
                HStack(spacing: 8) {
                    Text(commit.shortHash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tint)
                    Text(commit.author)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(commit.relativeDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if isPushed {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Déjà poussé sur l'amont")
                            .accessibilityLabel("Déjà poussé")
                    }
                }
            }
            Spacer(minLength: 4)
            // Rappel de l'action clic droit au survol.
            if hovering {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                    .help("Clic droit : rebase interactif depuis ce commit")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.08 : 0))
        )
        .overlay(alignment: .leading) {
            // Liseré d'accent à gauche : plein si sélectionné, discret au survol.
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2.5)
                .opacity(isSelected ? 1 : (hovering ? 0.6 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help("Cliquer pour voir le diff de ce commit")
    }

    /// Colonne « graphe » : trait vertical continu + pastille du commit, teintés à la
    /// couleur de la branche (gris pour les commits de la base).
    private var graphGutter: some View {
        ZStack {
            // Le trait ne dépasse ni en haut du 1er commit ni en bas du dernier.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : dotColor.opacity(0.45))
                    .frame(width: 2)
                Rectangle()
                    .fill(isLast ? Color.clear : dotColor.opacity(0.45))
                    .frame(width: 2)
            }
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }
}
