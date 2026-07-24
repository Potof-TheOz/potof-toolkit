import SwiftUI

/// Diff **interactif** d'un fichier du working tree (par opposition à `CommitDiffView`, en
/// lecture seule). Permet le staging par **hunk** et par **ligne** : coche des lignes →
/// reconstruction d'un patch minimal (`UnifiedFileDiff.buildPatch`) → `git apply` via le store.
///
/// Modes : « non indexé » (`git diff`) et « indexé » (`git diff --cached`). Un fichier non
/// suivi n'est stageable qu'en **entier** (v1) ; les fichiers binaires aussi.
struct WorkingDiffView: View {
    let file: FileStatus
    @ObservedObject var store: WorkingCopyStore
    var onClose: (() -> Void)?

    enum Mode: String { case unstaged, staged }

    /// Disposition unifié / côte à côte, préférence globale partagée (voir `DiffLayoutMode`).
    @AppStorage("gitStuffs.diffLayoutMode") private var layoutMode: DiffLayoutMode = .unified

    @State private var mode: Mode
    @State private var diff: UnifiedFileDiff?
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmDiscard = false

    init(file: FileStatus, store: WorkingCopyStore, initialMode: Mode? = nil, onClose: (() -> Void)? = nil) {
        self.file = file
        self.store = store
        self.onClose = onClose
        // Mode par défaut : les changements non indexés d'abord (ce qu'on est en train de
        // travailler) ; sinon l'indexé. `initialMode` (fourni selon la section cliquée :
        // INDEXÉ → .staged, NON INDEXÉ → .unstaged) prime, mais on retombe sur le défaut
        // s'il n'est pas applicable (ex. .staged demandé sur un fichier sans changement indexé).
        let fallback: Mode = (file.hasUnstagedChanges || file.isUntracked) ? .unstaged : .staged
        switch initialMode ?? fallback {
        case .staged:
            _mode = State(initialValue: file.isStaged ? .staged : fallback)
        case .unstaged:
            _mode = State(initialValue: (file.hasUnstagedChanges || file.isUntracked) ? .unstaged : fallback)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if hasBothModes {
                modePicker
                Divider()
            }
            content
            if canStageByLine {
                Divider()
                actionBar
            }
        }
        .frame(minWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: load)
        // Après une action git, le statut change (revision) → recharger le diff.
        .onChange(of: store.revision) { _ in load() }
        .confirmationDialog(
            "Jeter la sélection ?",
            isPresented: $confirmDiscard, titleVisibility: .visible
        ) {
            Button("Jeter", role: .destructive) { applyDiscardSelection() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les lignes sélectionnées seront définitivement retirées de la copie de travail.")
        }
    }

    // MARK: - En-tête

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(file.display)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .help(file.display)
            Spacer(minLength: 12)
            DiffLayoutToggle(mode: $layoutMode)
            if store.isBusy {
                ProgressView().controlSize(.small)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Fermer le diff (revenir au graphe)")
                .accessibilityLabel("Fermer le diff")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Non indexé").tag(Mode.unstaged)
            Text("Indexé").tag(Mode.staged)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: mode) { _ in load() }
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered { ProgressView(); Text("Lecture du diff…").font(.system(size: 12)).foregroundStyle(.secondary) }
        } else if let error {
            centered {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(.orange)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
        } else if file.isUntracked {
            untrackedContent
        } else if let diff, diff.isBinary {
            centered {
                Image(systemName: "doc").font(.system(size: 24)).foregroundStyle(.secondary)
                Text("Fichier binaire — staging du fichier entier uniquement.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Stager le fichier") { store.stage(file) }.disabled(store.isBusy)
            }
        } else if let diff, diff.isEmpty {
            centered {
                Image(systemName: "equal.circle").font(.system(size: 24)).foregroundStyle(.secondary)
                Text(mode == .staged ? "Aucune modification indexée." : "Aucune modification non indexée.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let diff {
            diffScroll(diff)
        }
    }

    private var untrackedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fichier non suivi").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Stager le fichier") { store.stage(file) }
                    .disabled(store.isBusy)
                    .help("Ajouter le fichier entier à l'index")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let diff, !diff.isEmpty {
                diffScroll(diff, readOnly: true)
            } else {
                centered {
                    Image(systemName: "doc.badge.plus").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("Nouveau fichier.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func diffScroll(_ diff: UnifiedFileDiff, readOnly: Bool = false) -> some View {
        ScrollView(.vertical) {
            // Côte à côte : VStack EAGER (pas Lazy). Les lignes ont des hauteurs variables
            // (texte à la ligne, colonnes appariées) ; un LazyVStack réserve alors l'espace
            // mais laisse les lignes hors du premier écran NON peintes → gros trous vides.
            // L'eager mesure/peint chaque ligne. Le mode unifié garde LazyVStack (lignes
            // simples, gros diffs fluides). `.id(layoutMode)` force une reconstruction propre
            // à la bascule (sinon le recyclage des lignes masque le changement de mode).
            Group {
                if layoutMode == .sideBySide {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            hunkHeaderRow(hunk, readOnly: readOnly)
                            ForEach(SideBySideDiff.pair(hunk.lines.map(\.asDiffLine))) { row in
                                sideBySideRow(row, readOnly: readOnly)
                            }
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            hunkHeaderRow(hunk, readOnly: readOnly)
                            ForEach(hunk.lines) { line in
                                lineRow(line, readOnly: readOnly)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .id(layoutMode)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func hunkHeaderRow(_ hunk: Hunk, readOnly: Bool) -> some View {
        HStack(spacing: 8) {
            if !readOnly && canStageByLine {
                Button {
                    toggleHunk(hunk)
                } label: {
                    Image(systemName: hunkFullySelected(hunk) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(hunkFullySelected(hunk) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Sélectionner / désélectionner tout le hunk")
                .accessibilityLabel("Sélectionner le hunk")
            }
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if !readOnly && canStageByLine {
                Button(mode == .staged ? "Déstager le hunk" : "Stager le hunk") {
                    applyHunk(hunk)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tint)
                .disabled(store.isBusy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05))
    }

    private func lineRow(_ line: PatchLine, readOnly: Bool) -> some View {
        let isChange = line.kind != .context
        let isSelected = selected.contains(line.id)
        return HStack(spacing: 0) {
            if !readOnly && canStageByLine {
                Group {
                    if isChange {
                        Button {
                            toggleLine(line)
                        } label: {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelected ? "Désélectionner la ligne" : "Sélectionner la ligne")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22)
            }
            DiffLineRow(line: line.asDiffLine, compactGutter: true)
        }
        .background(isChange && isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    // MARK: - Côte à côte

    /// Une ligne du rendu côte à côte : ancien à gauche, nouveau à droite. Alignement
    /// `.top` → les deux colonnes démarrent au même y et le `Divider` s'étire à la hauteur
    /// de la moitié la plus haute (rendu eager, cf. `diffScroll` ; pas de synchro de scroll).
    private func sideBySideRow(_ row: SideBySideDiffRow, readOnly: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            halfCell(row.left, .old, readOnly: readOnly)
            Divider()
            halfCell(row.right, .new, readOnly: readOnly)
        }
    }

    /// Une moitié : colonne case (22pt, comme en unifié) + `DiffHalfRow`. La case
    /// n'apparaît que sur une ligne de changement (retrait à gauche, ajout à droite) ;
    /// le contexte et les remplissages (`nil`) gardent la colonne vide pour l'alignement.
    private func halfCell(_ line: DiffLine?, _ side: DiffHalfRow.Side, readOnly: Bool) -> some View {
        let isChange = line != nil && line!.kind != .context
        let isSelected = line.map { selected.contains($0.id) } ?? false
        return HStack(spacing: 0) {
            if !readOnly && canStageByLine {
                Group {
                    if isChange, let line {
                        Button {
                            toggleLine(id: line.id)
                        } label: {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelected ? "Désélectionner la ligne" : "Sélectionner la ligne")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 22)
            }
            DiffHalfRow(line: line, side: side)
        }
        .frame(maxWidth: .infinity)
        .background(isChange && isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    // MARK: - Barre d'action (sélection courante)

    private var actionBar: some View {
        HStack(spacing: 10) {
            Text("\(selected.count) ligne\(selected.count > 1 ? "s" : "") sélectionnée\(selected.count > 1 ? "s" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 8)
            if mode == .staged {
                Button("Déstager la sélection") { applyUnstageSelection() }
                    .disabled(selected.isEmpty || store.isBusy)
            } else {
                Button(role: .destructive) { confirmDiscard = true } label: { Text("Jeter la sélection") }
                    .disabled(selected.isEmpty || store.isBusy)
                Button("Stager la sélection") { applyStageSelection() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(selected.isEmpty || store.isBusy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Chargement

    /// Staging par ligne possible ? (suivi, non binaire, diff non vide).
    private var canStageByLine: Bool {
        guard !file.isUntracked, let diff, !diff.isBinary, !diff.isEmpty else { return false }
        return true
    }

    private var hasBothModes: Bool {
        file.isStaged && (file.hasUnstagedChanges || file.isUntracked)
    }

    private func load() {
        isLoading = true
        error = nil
        let repo = store.repo
        let path = file.path
        let currentMode = mode
        let untracked = file.isUntracked
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Git.Result
            if untracked {
                // Fichier neuf : diff contre /dev/null (sortie « tout ajout »). `--no-index`
                // renvoie un code non nul quand il y a des différences → on ignore le code.
                result = Git.run(["diff", "--no-color", "--no-index", "--", "/dev/null", path], in: repo)
            } else if currentMode == .staged {
                result = Git.run(["diff", "--cached", "--no-color", "--", path], in: repo)
            } else {
                result = Git.run(["diff", "--no-color", "--", path], in: repo)
            }
            let parsed = UnifiedDiffParser.parse(result.stdout)
            DispatchQueue.main.async {
                self.diff = parsed
                // Sélection par défaut : toutes les lignes de changement.
                self.selected = parsed.allChangeIDs
                self.isLoading = false
            }
        }
    }

    // MARK: - Sélection

    private func toggleLine(_ line: PatchLine) { toggleLine(id: line.id) }

    private func toggleLine(id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func hunkChangeIDs(_ hunk: Hunk) -> [Int] {
        hunk.lines.filter { $0.kind != .context }.map(\.id)
    }

    private func hunkFullySelected(_ hunk: Hunk) -> Bool {
        let ids = hunkChangeIDs(hunk)
        return !ids.isEmpty && ids.allSatisfy { selected.contains($0) }
    }

    private func toggleHunk(_ hunk: Hunk) {
        let ids = hunkChangeIDs(hunk)
        if hunkFullySelected(hunk) {
            ids.forEach { selected.remove($0) }
        } else {
            ids.forEach { selected.insert($0) }
        }
    }

    // MARK: - Application

    /// Applique un hunk entier (indépendamment de la sélection de lignes).
    private func applyHunk(_ hunk: Hunk) {
        guard let diff else { return }
        let ids = Set(hunkChangeIDs(hunk))
        guard let patch = diff.buildPatch(selecting: ids) else { return }
        if mode == .staged { store.unstageSelection(patch) } else { store.stageSelection(patch) }
    }

    private func applyStageSelection() {
        guard let patch = diff?.buildPatch(selecting: selected) else { return }
        store.stageSelection(patch)
    }
    private func applyUnstageSelection() {
        guard let patch = diff?.buildPatch(selecting: selected) else { return }
        store.unstageSelection(patch)
    }
    private func applyDiscardSelection() {
        guard let patch = diff?.buildPatch(selecting: selected) else { return }
        store.discardSelection(patch)
    }

    // MARK: - Utilitaire

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}
