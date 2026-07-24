import SwiftUI
import AppKit

/// Espace de travail d'un worktree (modèle GitHub Desktop). Recréé par worktree (`.id(worktree.id)`).
///
/// - **Top bar** : sélecteur de worktree (`ProjectPicker`) + branche + badge de synchro (↑/↓/⚠️) +
///   actions Fetch · Pull · Push · Recharger.
/// - **Colonne gauche** : toggle **Modifications | Historique**.
///   - *Modifications* → fichiers en diff (`ChangesListView`) + boîte de commit.
///   - *Historique* → liste des commits (clic = diff à droite, clic droit = rebase).
/// - **Colonne droite** : diff du fichier working tree sélectionné, ou du commit sélectionné.
struct RepoDetailView: View {
    let worktree: Worktree
    /// Source des projets/worktrees pour le sélecteur (nommé `projects` pour ne pas entrer
    /// en collision avec le `@StateObject private var store: WorkingCopyStore`).
    let projects: ProjectStore
    let onSelect: (Worktree) -> Void

    @StateObject private var detail: RepoDetail
    /// Couche « working copy » (statut, staging, commit, push/pull, auto-fetch).
    @StateObject private var store: WorkingCopyStore

    enum Tab: Hashable { case changes, history }
    @State private var tab: Tab = .changes

    /// Contrôleur du rebase courant, ou nil.
    @State private var rebase: RebaseController?
    /// Commit dont on affiche le diff (onglet Historique), ou nil.
    @State private var diffTarget: CommitDiffTarget?
    /// Fichier du working tree dont on affiche le diff interactif (onglet Modifications).
    @State private var selectedWorkingFileID: FileStatus.ID?
    /// Résolveur de conflits (pull --rebase en conflit), ou nil. Remplace tout le centre.
    @State private var conflictResolver: ConflictResolver?

    init(worktree: Worktree, projects: ProjectStore, onSelect: @escaping (Worktree) -> Void) {
        self.worktree = worktree
        self.projects = projects
        self.onSelect = onSelect
        _detail = StateObject(wrappedValue: RepoDetail(repo: worktree.url))
        _store  = StateObject(wrappedValue: WorkingCopyStore(repo: worktree.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let controller = rebase {
                RebasePanelView(controller: controller, onClose: {
                    rebase = nil
                    detail.load()
                    store.refresh()
                })
            } else if let resolver = conflictResolver {
                ConflictResolutionView(resolver: resolver)
            } else {
                if detail.rebaseInProgress {
                    inProgressBanner
                    Divider()
                }
                workspaceSplit
            }
        }
        .background(.background)
        .onAppear {
            store.onHistoryChanged = { [weak detail] in detail?.load() }
            detail.load()
            store.refresh()
            store.startAutoFetch()
        }
        .onDisappear { store.stopAutoFetch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            ProjectPicker(store: projects, current: worktree, onSelect: onSelect)
            WorktreePicker(store: projects, current: worktree,
                           branch: detail.branch, isDetached: detail.isDetached, onSelect: onSelect)
            syncBadge
            Spacer(minLength: 12)
            syncActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var syncBadge: some View {
        HStack(spacing: 8) {
            if store.isFetching { ProgressView().controlSize(.small) }
            if store.sync.hasUpstream {
                if store.sync.isBehind {
                    Label("\(store.sync.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.orange)
                        .help("\(store.sync.behind) commit(s) distant(s) non récupéré(s)")
                }
                if store.sync.isAhead {
                    Label("\(store.sync.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.tint)
                        .help("\(store.sync.ahead) commit(s) local(aux) non poussé(s)")
                }
                if !store.sync.isBehind && !store.sync.isAhead && !store.sync.fetchFailed {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        .help("À jour avec l'amont")
                }
                if store.sync.fetchFailed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        .help("Le fetch a échoué (authentification ou réseau ?).")
                }
            } else {
                Image(systemName: "cloud.slash").foregroundStyle(.secondary)
                    .help("Aucune branche amont. Push la publiera (origin).")
            }
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit()
        .labelStyle(.titleAndIcon)
    }

    private var syncActions: some View {
        HStack(spacing: 12) {
            barButton("arrow.down.circle", help: "Fetch (récupérer l'état distant)",
                      label: "Fetch", disabled: store.isFetching || store.isBusy) { store.fetch() }
            barButton("arrow.down.to.line", help: "Pull (rebase)",
                      label: "Pull (rebase)", disabled: store.isBusy || !store.sync.hasUpstream) { store.pullRebase() }
            barButton("arrow.up.to.line", help: "Push",
                      label: "Push", disabled: store.isBusy) { store.push() }
            barButton("arrow.clockwise", help: "Recharger branche, commits et statut",
                      label: "Recharger", disabled: false) { detail.load(); store.refresh() }
        }
    }

    private func barButton(_ systemName: String, help: String, label: String,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(disabled)
            .help(help).accessibilityLabel(label)
    }

    // MARK: - Split principal (colonne gauche à onglets + diff)

    private var workspaceSplit: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
            rightPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Modifications").tag(Tab.changes)
                Text("Historique").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if tab == .changes {
                ChangesListView(
                    store: store,
                    selectedFileID: selectedWorkingFileID,
                    onSelectFile: { selectedWorkingFileID = $0.id }
                )
            } else {
                historyList
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var rightPane: some View {
        if tab == .changes {
            changesRightPane
        } else {
            historyRightPane
        }
    }

    // MARK: - Volet droit : Modifications

    @ViewBuilder
    private var changesRightPane: some View {
        if let file = liveSelectedFile {
            WorkingDiffView(file: file, store: store, onClose: { selectedWorkingFileID = nil })
                // Recréer la vue (donc réinitialiser `mode`) quand la composition staged/
                // unstaged du fichier change : sinon `mode` reste figé (ex. après avoir tout
                // stagé un fichier non indexé, on reste bloqué sur un diff non indexé vide).
                .id("\(file.id)#\(file.isStaged)\(file.hasUnstagedChanges)\(file.isUntracked)")
        } else {
            placeholder(icon: store.isClean ? "checkmark.seal" : "sidebar.left",
                        text: store.isClean
                            ? "Arbre de travail propre."
                            : "Sélectionne un fichier modifié à gauche pour voir et stager son diff.")
        }
    }

    /// Fichier sélectionné relu depuis l'état courant (nil s'il a disparu, ex. après commit).
    private var liveSelectedFile: FileStatus? {
        guard let id = selectedWorkingFileID else { return nil }
        return store.files.first { $0.id == id }
    }

    // MARK: - Volet droit : Historique

    @ViewBuilder
    private var historyRightPane: some View {
        if let target = diffTarget {
            CommitDiffView(target: target, onClose: { diffTarget = nil })
                .id(target.id)
        } else {
            placeholder(icon: "clock.arrow.circlepath",
                        text: "Sélectionne un commit à gauche pour voir ses modifications.")
        }
    }

    private func diffTarget(for commit: GitCommit) -> CommitDiffTarget {
        CommitDiffTarget(repo: worktree.url, hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject)
    }

    // MARK: - Liste des commits (colonne gauche, onglet Historique)

    @ViewBuilder
    private var historyList: some View {
        if detail.isLoading && detail.commits.isEmpty {
            placeholder(icon: nil, text: "Lecture de l'historique…", spinner: true)
        } else if let error = detail.loadError {
            placeholder(icon: "exclamationmark.triangle", text: error, tint: .orange)
        } else if detail.commits.isEmpty {
            placeholder(icon: "tray", text: "Aucun commit sur cette branche.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Clic : diff · clic droit : rebase")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(detail.commits.enumerated()), id: \.element.id) { index, commit in
                            if index == forkBoundaryIndex { forkDivider }
                            let isOwn = detail.branchOwnHashes.contains(commit.hash)
                            CommitRow(
                                commit: commit,
                                isFirst: index == 0,
                                isLast: index == detail.commits.count - 1,
                                isPushed: detail.pushedHashes.contains(commit.hash),
                                dotColor: isOwn ? branchColor(detail.branch) : .secondary,
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
    }

    /// Séparateur marquant le point de création de la branche (bascule vers la base).
    private var forkDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text("Création de « \(detail.branch) »" + (detail.baseBranchName.map { " · \($0)" } ?? ""))
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    /// Menu contextuel d'un commit : diff (lecture seule) + rebase interactif encadré.
    @ViewBuilder
    private func commitMenu(index: Int) -> some View {
        let commit = detail.commits[index]
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
                    repo: worktree.url,
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

    /// Nombre de commits en tête propres à la branche (borne la plage rebasable).
    private var branchOwnLeadingCount: Int {
        var count = 0
        for commit in detail.commits {
            if detail.branchOwnHashes.contains(commit.hash) { count += 1 } else { break }
        }
        return count
    }

    /// Index du 1er commit de la base (frontière de création), ou nil si non pertinent.
    private var forkBoundaryIndex: Int? {
        guard detail.baseBranchName != nil else { return nil }
        let k = branchOwnLeadingCount
        return (k > 0 && k < detail.commits.count) ? k : nil
    }

    /// Couleur stable dérivée du nom de branche (déterministe).
    private func branchColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint, .cyan]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette.isEmpty ? .accentColor : palette[sum % palette.count]
    }

    // MARK: - Bannière rebase en cours

    private var inProgressBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Un rebase est déjà en cours dans ce repo.")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if !store.conflictedFiles.isEmpty {
                Button("Résoudre les conflits") {
                    let resolver = ConflictResolver(repo: worktree.url)
                    resolver.onFinished = {
                        conflictResolver = nil
                        detail.load()
                        store.refresh()
                    }
                    conflictResolver = resolver
                }
                .help("Résoudre les conflits dans l'app (bloc par bloc ou édition libre)")
            }
            Button("Reprendre le contrôle") {
                let controller = RebaseController(repo: worktree.url, commits: detail.commits, upstream: detail.upstream)
                controller.attachToInProgress()
                rebase = controller
            }
            .help("Voir la sortie git brute et continuer / abandonner à la main")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Placeholder générique

    private func placeholder(icon: String?, text: String, tint: Color = .secondary, spinner: Bool = false) -> some View {
        VStack(spacing: 10) {
            if spinner { ProgressView() }
            if let icon {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(.background)
    }
}

// MARK: - Ligne de commit (liste d'historique)

private struct CommitRow: View {
    let commit: GitCommit
    let isFirst: Bool
    let isLast: Bool
    let isPushed: Bool
    let dotColor: Color
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            graphGutter
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .font(.system(size: 12)).lineLimit(2)
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
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tint)
                    Text(commit.author)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").foregroundStyle(.secondary)
                    Text(commit.relativeDate)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if isPushed {
                        Image(systemName: "cloud.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            .help("Déjà poussé sur l'amont").accessibilityLabel("Déjà poussé")
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.08 : 0)))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 2.5)
                .opacity(isSelected ? 1 : (hovering ? 0.6 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help("Cliquer pour voir le diff · clic droit pour rebaser")
    }

    private var graphGutter: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : dotColor.opacity(0.45)).frame(width: 2)
                Rectangle().fill(isLast ? Color.clear : dotColor.opacity(0.45)).frame(width: 2)
            }
            Circle().fill(dotColor).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }
}
