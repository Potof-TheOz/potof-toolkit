import SwiftUI

/// Colonne « Modifications » (onglet gauche du repo) : sections CONFLITS / INDEXÉ / MODIFIÉ /
/// NON SUIVI, chacune rendue en **arborescence** (`FileTreeView`) avec actions par fichier
/// (survol) et par dossier. Boîte de commit (sujet + description repliée) en bas.
struct ChangesListView: View {
    @ObservedObject var store: WorkingCopyStore
    /// Fichier dont le diff est affiché à droite (surlignage), ou `nil`.
    let selectedFileID: FileStatus.ID?
    /// Mode de la sélection courante (indexé / non indexé). Un fichier « MM » apparaît dans
    /// les deux sections → on ne surligne que celle qui correspond à ce mode.
    let selectedMode: WorkingDiffView.Mode
    /// Clic sur un fichier : porte le mode de la section (INDEXÉ → .staged, NON INDEXÉ → .unstaged).
    let onSelectFile: (FileStatus, WorkingDiffView.Mode) -> Void

    /// Corps de message déplié ? (replié par défaut : peu utilisé.)
    @State private var showsBody = false
    /// Fichier en attente de confirmation de « jeter ».
    @State private var pendingDiscard: FileStatus?
    /// Dossiers repliés (partagé par toutes les sections ; clé = chemin, unique).
    @State private var collapsedFolders: Set<String> = []

    /// Action au niveau dossier proposée par une section.
    private enum FolderAction { case stage, unstage }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.actionError {
                errorBanner(error)
                Divider()
            }
            fileSections
            Divider()
            commitBox
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .confirmationDialog(
            "Jeter les modifications de « \(pendingDiscard?.display ?? "") » ?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible
        ) {
            Button("Jeter les modifications", role: .destructive) {
                if let file = pendingDiscard { store.discard(file) }
                pendingDiscard = nil
            }
            Button("Annuler", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("Cette action est irréversible.")
        }
    }

    // MARK: - Sections de fichiers

    @ViewBuilder
    private var fileSections: some View {
        if store.isClean {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucune modification").font(.system(size: 12, weight: .medium))
                Text("L'arbre de travail est propre.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Conflits", files: store.conflictedFiles, folder: nil, mode: .unstaged)
                    section("Indexé", files: store.stagedFiles, folder: .unstage, mode: .staged,
                            allAction: store.stagedFiles.isEmpty ? nil : ("Tout déstager", { store.unstageAll() }))
                    // « Non indexé » fusionne modifiés-non-stagés + non-suivis ; les pastilles
                    // (M orange, ? vert, D rouge…) différencient les statuts.
                    section("Non indexé", files: store.unstagedFiles + store.untrackedFiles, folder: .stage, mode: .unstaged,
                            allAction: nonStagedEmpty ? nil : ("Tout stager", { store.stageAll() }))
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var nonStagedEmpty: Bool { store.unstagedFiles.isEmpty && store.untrackedFiles.isEmpty }

    @ViewBuilder
    private func section(_ title: String, files: [FileStatus],
                         folder: FolderAction?,
                         mode: WorkingDiffView.Mode,
                         allAction: (label: String, action: () -> Void)? = nil) -> some View {
        if !files.isEmpty {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text("\(files.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 4)
                if let allAction {
                    Button(allAction.label, action: allAction.action)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tint).disabled(store.isBusy).help(allAction.label)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)

            FileTreeView(
                items: files.map { FileTreeItem(path: $0.path, value: $0) },
                collapsed: $collapsedFolders,
                // Ne surligner que si la sélection courante vise CETTE section (sinon un
                // fichier « MM » s'allumerait dans les deux).
                selectedPath: selectedMode == mode ? selectedFileID : nil,
                namespace: title,
                onSelect: { onSelectFile($0, mode) },
                leading: { badge($0) },
                trailing: { fileActions($0) },
                folderTrailing: { path, _ in folderButton(folder, path: path) }
            )
        }
    }

    // MARK: - Contenus injectés dans l'arbre

    /// Pastille de statut (lettre) du fichier, colorée **par statut** pour différencier les
    /// modifiés / ajoutés / supprimés / non-suivis dans une liste fusionnée.
    private func badge(_ file: FileStatus) -> some View {
        let tint = badgeTint(file)
        return Text(String(file.badge))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 16, height: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.18)))
            .accessibilityHidden(true)
    }

    /// Couleur de la pastille selon la lettre de statut git.
    private func badgeTint(_ file: FileStatus) -> Color {
        switch file.badge {
        case "M":            return .orange   // modifié
        case "A":            return .green    // ajouté (indexé)
        case "?":            return .green    // non suivi (nouveau)
        case "D":            return .red      // supprimé
        case "R", "C":       return .blue     // renommé / copié
        case "U":            return .red      // conflit
        default:             return .secondary
        }
    }

    @ViewBuilder
    private func fileActions(_ file: FileStatus) -> some View {
        if file.isConflicted {
            Text("conflit").font(.system(size: 9, weight: .semibold)).foregroundStyle(.red)
        } else {
            HStack(spacing: 8) {
                if file.isStaged {
                    iconButton("minus.circle.fill", help: "Déstager ce fichier",
                               label: "Déstager \(file.path)", tint: .orange, disabled: store.isBusy) { store.unstage(file) }
                }
                if file.hasUnstagedChanges || file.isUntracked {
                    iconButton("arrow.uturn.backward.circle", help: "Jeter les modifications de ce fichier",
                               label: "Jeter \(file.path)", tint: .secondary, disabled: store.isBusy) { pendingDiscard = file }
                    iconButton("plus.circle.fill", help: "Stager ce fichier",
                               label: "Stager \(file.path)", tint: .accentColor, disabled: store.isBusy) { store.stage(file) }
                }
            }
        }
    }

    @ViewBuilder
    private func folderButton(_ action: FolderAction?, path: String) -> some View {
        switch action {
        case .stage:
            iconButton("plus.circle.fill", help: "Stager tout le dossier",
                       label: "Stager le dossier \(path)", tint: .accentColor, disabled: store.isBusy) { store.stageFolder(path) }
        case .unstage:
            iconButton("minus.circle.fill", help: "Déstager tout le dossier",
                       label: "Déstager le dossier \(path)", tint: .orange, disabled: store.isBusy) { store.unstageFolder(path) }
        case .none:
            EmptyView()
        }
    }

    // MARK: - Boîte de commit

    private var commitBox: some View {
        VStack(spacing: 8) {
            TextField("Message de commit (sujet)", text: $store.commitSubject)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onSubmit { if store.canCommit { store.commit() } }

            if showsBody {
                TextEditor(text: $store.commitBody)
                    .font(.system(size: 12)).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsBody.toggle() }
                } label: {
                    Label(showsBody ? "Masquer la description" : "+ description",
                          systemImage: showsBody ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Corps de message optionnel (multi-lignes)")

                Button { store.generateCommitMessage() } label: {
                    HStack(spacing: 4) {
                        if store.isGeneratingMessage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(store.isGeneratingMessage ? "Génération…" : "Générer")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.canGenerateMessage ? Color.accentColor : .secondary)
                .disabled(!store.canGenerateMessage)
                .help(store.hasStagedChanges
                      ? "Générer le message depuis les fichiers indexés (skill Claude)"
                      : "Indexez d'abord des fichiers")
                .accessibilityLabel("Générer le message de commit")

                Spacer(minLength: 8)

                if store.isBusy, let action = store.busyAction {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(action).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Button { store.commit() } label: { Text("Commit").frame(minWidth: 60) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canCommit)
                    .help("Committer les changements indexés (⌘↩)")
            }
        }
        .padding(12)
        .background(.bar)
        // La skill peut produire un corps multi-lignes → on déplie la zone description.
        .onChange(of: store.commitBody) { newValue in
            if !newValue.isEmpty { showsBody = true }
        }
    }

    // MARK: - Utilitaires

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.system(size: 11)).foregroundStyle(.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { store.actionError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).help("Masquer l'erreur").accessibilityLabel("Masquer l'erreur")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// Bouton-icône compact avec `.help` **et** `.accessibilityLabel` (invariant du projet).
    /// `tint` colore l'icône pour la rendre bien visible quand elle apparaît au survol.
    private func iconButton(_ systemName: String, help: String, label: String,
                            tint: Color = .secondary, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).font(.system(size: 15)) }
            .buttonStyle(.plain).foregroundStyle(tint).disabled(disabled)
            .help(help).accessibilityLabel(label)
    }
}
