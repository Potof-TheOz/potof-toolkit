import SwiftUI

/// Sélecteur de **worktree** (branche) du projet courant, dans la barre du haut, à côté du
/// `ProjectPicker`. Deux niveaux séparés : le `ProjectPicker` choisit le **projet**, celui-ci
/// choisit **quel worktree** de ce projet est ouvert.
///
/// - Si le projet courant a **plusieurs** worktrees ouvrables → bouton « ⑂ branche ▾ » +
///   popover listant les worktrees frères.
/// - Sinon → simple libellé « ⑂ branche » (pas de menu).
///
/// Le texte de la branche vient de l'état **live** du détail (`RepoDetail.branch`), pour rester
/// exact même si un checkout a eu lieu ; la liste des frères vient du `ProjectStore`.
struct WorktreePicker: View {
    @ObservedObject var store: ProjectStore
    let current: Worktree
    /// Branche live (depuis `RepoDetail`), ou vide en cours de chargement.
    let branch: String
    let isDetached: Bool
    let onSelect: (Worktree) -> Void

    @State private var isOpen = false

    /// Worktrees ouvrables du projet courant (exclut le bare).
    private var siblings: [Worktree] {
        guard let project = store.project(containing: current) else { return [] }
        return store.worktrees(for: project).filter { !$0.isBare }
    }

    var body: some View {
        if siblings.count > 1 {
            Button { isOpen.toggle() } label: { label(chevron: true) }
                .buttonStyle(.plain)
                .help("Changer de worktree / branche")
                .accessibilityLabel("Sélecteur de worktree, actuel : \(branch.isEmpty ? "…" : branch)")
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    popoverContent.frame(width: 300, height: min(320, CGFloat(siblings.count) * 42 + 60))
                }
        } else {
            label(chevron: false)
                .help(isDetached ? "HEAD détaché" : "Branche courante")
        }
    }

    // MARK: - Libellé

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                .accessibilityHidden(true)
            Text(branch.isEmpty ? "…" : branch)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDetached ? Color.orange : .secondary)
                .lineLimit(1).truncationMode(.middle)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Popover (liste des worktrees frères)

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Worktrees").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(siblings) { worktree in
                        WorktreeChoiceRow(worktree: worktree, isSelected: worktree.id == current.id) {
                            onSelect(worktree)
                            isOpen = false
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Ligne de worktree (popover)

private struct WorktreeChoiceRow: View {
    let worktree: Worktree
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                // Nom de dossier rappelé s'il diffère de l'étiquette (désambiguïse deux worktrees).
                if worktree.folderName != worktree.displayLabel {
                    Text(worktree.folderName)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if isSelected {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(worktree.url.path)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Ouvrir le worktree \(worktree.displayLabel)")
    }
}
