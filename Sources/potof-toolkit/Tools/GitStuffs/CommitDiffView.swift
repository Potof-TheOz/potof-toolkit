import SwiftUI

/// Cible d'affichage de diff : un commit d'un repo. `Identifiable` pour `.sheet(item:)`.
struct CommitDiffTarget: Identifiable {
    var id: String { hash }
    let repo: URL
    let hash: String
    let shortHash: String
    let subject: String
}

/// Aperçu **lecture seule** des modifications d'un commit, mutualisant le rendu du
/// pont IDE : `DiffComputer` (LCS ligne-à-ligne) + `DiffLineRow` (Core/Diff). Un
/// bouton ferme le panneau (`onClose`). N'écrit jamais rien (via `git show`).
struct CommitDiffView: View {
    let target: CommitDiffTarget
    /// Ferme le panneau (efface la sélection côté graphe, ou ferme la feuille). `nil`
    /// = pas de bouton fermer (panneau toujours présent, ex. à droite du rebase).
    var onClose: (() -> Void)?

    /// Disposition unifié / côte à côte, préférence globale partagée (voir `DiffLayoutMode`).
    @AppStorage("gitStuffs.diffLayoutMode") private var layoutMode: DiffLayoutMode = .unified

    @State private var files: [FileChange] = []
    /// Fichier dont le diff est affiché en bas (arbre en haut). Défaut : le 1er.
    @State private var selectedFileID: FileChange.ID?
    @State private var isLoading = true
    @State private var error: String?
    @State private var truncated = false
    /// Dossiers repliés de l'arbre de fichiers (détenu ici, cf. `FileTreeView`).
    @State private var collapsedFolders: Set<String> = []

    /// Bornes d'affichage (fluidité sur gros commits).
    private static let maxFiles = 40
    private static let maxTotalLines = 6000
    /// Lignes de contexte conservées de part et d'autre de chaque modif (le reste du
    /// fichier est replié en un séparateur), pour limiter la hauteur.
    private static let contextLines = 5

    /// Élément d'affichage d'un fichier : une ligne de diff, ou un repli de N lignes
    /// inchangées.
    struct DiffDisplayItem: Identifiable {
        enum Content { case line(DiffLine); case gap(Int) }
        let id: Int
        let content: Content
    }

    struct FileChange: Identifiable {
        enum Status { case added, modified, deleted, renamed, typeChange }
        var id: String { display }
        let status: Status
        let display: String       // « path » ou « old → new » (renommage)
        /// Chemin réel pour placer le fichier dans l'arbre (nouveau chemin ; ancien si suppression).
        let path: String
        let diff: FileDiff
        /// Lignes repliées au contexte de `contextLines` (rendu limité en hauteur).
        let items: [DiffDisplayItem]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .frame(minWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: load)
    }

    // MARK: - En-tête

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.subject)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(target.shortHash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !files.isEmpty {
                Text("+\(totalAdded)")
                    .foregroundStyle(.green)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Text("−\(totalRemoved)")
                    .foregroundStyle(.red)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            DiffLayoutToggle(mode: $layoutMode)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Fermer le diff")
                .accessibilityLabel("Fermer le diff")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Lecture du diff…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            centered(icon: "exclamationmark.triangle", text: error, tint: .orange)
        } else if files.isEmpty {
            centered(icon: "equal.circle",
                     text: "Aucune modification (commit vide ou de fusion).", tint: .secondary)
        } else {
            // Arbre des fichiers en haut (hauteur bornée à son contenu), diff en bas.
            VStack(spacing: 0) {
                fileTree
                    .frame(height: treeHeight)
                Divider()
                selectedFileDiff
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Hauteur de l'arbre : ~ contenu, plafonnée pour laisser la place au diff.
    private var treeHeight: CGFloat {
        min(max(CGFloat(files.count) * 26 + 14, 52), 220)
    }

    /// Arbre des fichiers touchés (statut + compteurs). Réutilise le composant générique
    /// `FileTreeView` (mêmes chrome/pliage que la liste des modifications).
    private var fileTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FileTreeView(
                    items: files.map { FileTreeItem(path: $0.path, value: $0) },
                    collapsed: $collapsedFolders,
                    selectedPath: selectedPath,
                    onSelect: { selectedFileID = $0.id },
                    leading: { statusChip($0.status) },
                    trailing: { fileCounts($0) },
                    folderTrailing: { _, _ in EmptyView() }
                )
                if truncated {
                    Text("… d'autres fichiers non affichés (diff volumineux).")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
            .padding(6)
        }
    }

    /// Chemin du fichier sélectionné (pour le surlignage de l'arbre).
    private var selectedPath: String? {
        files.first { $0.id == selectedFileID }?.path
    }

    private func fileCounts(_ file: FileChange) -> some View {
        HStack(spacing: 8) {
            Text("+\(file.diff.addedCount)").foregroundStyle(.green)
            Text("−\(file.diff.removedCount)").foregroundStyle(.red)
        }
        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
    }

    /// Diff du fichier sélectionné (lignes repliées au contexte).
    @ViewBuilder
    private var selectedFileDiff: some View {
        if let id = selectedFileID, let file = files.first(where: { $0.id == id }) {
            if file.diff.isBinary {
                fileNote("Fichier binaire — aperçu indisponible.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .textBackgroundColor))
            } else if file.items.isEmpty {
                fileNote("Aucune différence de contenu (changement de mode ou renommage seul).")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                ScrollView(.vertical) {
                    // Côte à côte : VStack EAGER (cf. WorkingDiffView) — un LazyVStack laisse
                    // les lignes appariées hors écran non peintes (hauteurs variables). Unifié :
                    // LazyVStack (fluide). `.id(layoutMode)` = bascule immédiate et propre.
                    Group {
                        if layoutMode == .sideBySide {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(sideBySideItems(file.items)) { item in
                                    switch item {
                                    case .row(let row): commitSideBySideRow(row)
                                    case .gap(_, let n): gapRow(n)
                                    }
                                }
                            }
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(file.items) { item in
                                    switch item.content {
                                    case .line(let line): DiffLineRow(line: line, compactGutter: true)
                                    case .gap(let n):     gapRow(n)
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
        } else {
            Text("Sélectionnez un fichier ci-dessus.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    /// Séparateur de repli entre deux zones modifiées (lignes inchangées masquées).
    private func gapRow(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .center)   // aligné sur la gouttière compacte
                .accessibilityHidden(true)
            Text("\(count) ligne\(count > 1 ? "s" : "") inchangée\(count > 1 ? "s" : "")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Côte à côte

    /// Élément d'affichage côte à côte : une ligne appariée, ou un repli de contexte.
    /// Gaps et lignes partagent un même espace d'`id` → ids uniques pour `ForEach`.
    private enum SxSDisplayItem: Identifiable {
        case row(SideBySideDiffRow)
        case gap(id: Int, count: Int)
        var id: Int { switch self { case .row(let r): return r.id; case .gap(let id, _): return id } }
    }

    /// Transforme les `DiffDisplayItem` (déjà repliés) en éléments côte à côte : on
    /// accumule les lignes consécutives puis on les apparie via `SideBySideDiff.pair`,
    /// et chaque `.gap` réémet un repli pleine largeur. Correct car un `.gap` ne remplace
    /// que du **contexte** (`collapse` garde ≥ `contextLines` autour de chaque modif) →
    /// les piles d'appariement sont toujours vides au bord d'un gap.
    private func sideBySideItems(_ items: [DiffDisplayItem]) -> [SxSDisplayItem] {
        var out: [SxSDisplayItem] = []
        var buffer: [DiffLine] = []
        var id = 0
        func flushRun() {
            guard !buffer.isEmpty else { return }
            for r in SideBySideDiff.pair(buffer) {
                out.append(.row(SideBySideDiffRow(id: id, left: r.left, right: r.right)))
                id += 1
            }
            buffer.removeAll(keepingCapacity: true)
        }
        for item in items {
            switch item.content {
            case .line(let l): buffer.append(l)
            case .gap(let n):  flushRun(); out.append(.gap(id: id, count: n)); id += 1
            }
        }
        flushRun()
        return out
    }

    /// Une ligne appariée : ancien à gauche, nouveau à droite (lecture seule, pas de case).
    private func commitSideBySideRow(_ row: SideBySideDiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            DiffHalfRow(line: row.left, side: .old)
            Divider()
            DiffHalfRow(line: row.right, side: .new)
        }
    }

    /// Réduit les lignes au contexte de `contextLines` autour de chaque modif ; les
    /// longues zones inchangées deviennent un repli `.gap`. Renvoie `[]` si le fichier
    /// n'a aucune modification de contenu (seulement du contexte).
    private static func collapse(_ lines: [DiffLine]) -> [DiffDisplayItem] {
        guard !lines.isEmpty else { return [] }
        var keep = [Bool](repeating: false, count: lines.count)
        var hasChange = false
        for (i, line) in lines.enumerated() where line.kind != .context {
            hasChange = true
            let lo = max(0, i - contextLines), hi = min(lines.count - 1, i + contextLines)
            for j in lo...hi { keep[j] = true }
        }
        guard hasChange else { return [] }

        var items: [DiffDisplayItem] = []
        var id = 0
        var dropped = 0
        func flushGap() {
            if dropped > 0 { items.append(DiffDisplayItem(id: id, content: .gap(dropped))); id += 1; dropped = 0 }
        }
        for i in 0..<lines.count {
            if keep[i] {
                flushGap()
                items.append(DiffDisplayItem(id: id, content: .line(lines[i]))); id += 1
            } else {
                dropped += 1
            }
        }
        flushGap()
        return items
    }

    private func statusChip(_ status: FileChange.Status) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .added:      return ("A", .green)
            case .modified:   return ("M", .orange)
            case .deleted:    return ("D", .red)
            case .renamed:    return ("R", .blue)
            case .typeChange: return ("T", .purple)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.18)))
    }

    private func centered(icon: String, text: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var totalAdded: Int { files.reduce(0) { $0 + $1.diff.addedCount } }
    private var totalRemoved: Int { files.reduce(0) { $0 + $1.diff.removedCount } }

    // MARK: - Chargement (git show + DiffComputer, en tâche de fond)

    private func load() {
        let repo = target.repo
        let hash = target.hash
        DispatchQueue.global(qos: .userInitiated).async {
            // `-M` détecte les renommages ; `--format=` supprime l'en-tête du commit.
            let nameStatus = Git.run(["show", "--name-status", "--format=", "--no-color", "-M", hash], in: repo)
            guard nameStatus.ok else {
                DispatchQueue.main.async {
                    self.error = nameStatus.message.isEmpty ? "Impossible de lire le commit." : nameStatus.message
                    self.isLoading = false
                }
                return
            }

            var changes: [FileChange] = []
            var totalLines = 0
            var didTruncate = false
            let rows = nameStatus.stdout.split(separator: "\n", omittingEmptySubsequences: true)

            for raw in rows {
                if changes.count >= Self.maxFiles || totalLines >= Self.maxTotalLines {
                    didTruncate = true
                    break
                }
                let fields = raw.components(separatedBy: "\t")
                guard let code = fields.first, let letter = code.first else { continue }

                let status: FileChange.Status
                let oldPath: String, newPath: String, display: String
                switch letter {
                case "A":
                    status = .added
                    oldPath = ""; newPath = fields.count > 1 ? fields[1] : ""; display = newPath
                case "D":
                    status = .deleted
                    oldPath = fields.count > 1 ? fields[1] : ""; newPath = ""; display = oldPath
                case "R":
                    status = .renamed
                    oldPath = fields.count > 2 ? fields[1] : ""
                    newPath = fields.count > 2 ? fields[2] : ""
                    display = "\(oldPath) → \(newPath)"
                case "C":
                    status = .modified
                    oldPath = fields.count > 2 ? fields[1] : ""
                    newPath = fields.count > 2 ? fields[2] : ""
                    display = "\(oldPath) → \(newPath)"
                case "T":
                    status = .typeChange
                    oldPath = fields.count > 1 ? fields[1] : ""; newPath = oldPath; display = oldPath
                default:
                    status = .modified
                    oldPath = fields.count > 1 ? fields[1] : ""; newPath = oldPath; display = oldPath
                }

                // Contenu ancien (depuis le parent) / nouveau (depuis le commit).
                var oldContent = ""
                var isNew = (status == .added)
                if !isNew && !oldPath.isEmpty {
                    let res = Git.run(["show", "\(hash)^:\(oldPath)"], in: repo)
                    if res.ok { oldContent = res.stdout } else { isNew = true } // commit racine : pas de parent
                }
                var newContent = ""
                if status != .deleted && !newPath.isEmpty {
                    let res = Git.run(["show", "\(hash):\(newPath)"], in: repo)
                    newContent = res.ok ? res.stdout : ""
                }

                let fd = DiffComputer.compute(oldContent: oldContent, newContent: newContent, isNewFile: isNew)
                let items = Self.collapse(fd.lines)
                // Le coût affiché = lignes réellement rendues (repli inclus), pas la
                // taille du fichier : un gros fichier peu modifié reste bon marché.
                totalLines += items.reduce(0) { acc, item in
                    if case .line = item.content { return acc + 1 } else { return acc }
                }
                let treePath = !newPath.isEmpty ? newPath : oldPath
                changes.append(FileChange(status: status, display: display, path: treePath, diff: fd, items: items))
            }

            let result = changes
            let trunc = didTruncate
            DispatchQueue.main.async {
                self.files = result
                self.selectedFileID = result.first?.id
                self.truncated = trunc
                self.isLoading = false
            }
        }
    }
}
