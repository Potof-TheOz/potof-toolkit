import SwiftUI

/// Écran de résolution de conflits **dans l'app** : à gauche la liste des fichiers en
/// conflit, à droite le fichier courant bloc par bloc (garder le nôtre / le leur / les deux)
/// ou en édition manuelle. En bas : Continuer (quand tout est stagé) / Abandonner.
struct ConflictResolutionView: View {
    @ObservedObject var resolver: ConflictResolver

    @State private var isManualEditing = false
    @State private var manualText = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let message = resolver.message {
                banner(message)
                Divider()
            }
            HSplitView {
                filesList
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                fileEditor
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(.background)
        .onAppear { resolver.reload() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Résolution de conflits")
                .font(.system(size: 13, weight: .semibold))
            if !resolver.files.isEmpty {
                Text("\(resolver.files.count) fichier\(resolver.files.count > 1 ? "s" : "") restant\(resolver.files.count > 1 ? "s" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            if resolver.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Liste des fichiers

    private var filesList: some View {
        VStack(spacing: 0) {
            if resolver.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Tous les conflits résolus").font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Continuez le rebase ci-dessous.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(resolver.files, id: \.self) { path in
                            fileRow(path)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(.background)
    }

    private func fileRow(_ path: String) -> some View {
        let selected = resolver.current?.path == path
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(selected ? 0.16 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { isManualEditing = false; resolver.select(path) }
        .help(path)
    }

    // MARK: - Éditeur de fichier

    @ViewBuilder
    private var fileEditor: some View {
        if let file = resolver.current {
            VStack(spacing: 0) {
                editorToolbar(file)
                Divider()
                if isManualEditing {
                    manualEditor
                } else {
                    hunksScroll(file)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 26)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun fichier à résoudre").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorToolbar(_ file: ConflictFile) -> some View {
        HStack(spacing: 10) {
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: 8)
            if !isManualEditing {
                Button("Tout : le nôtre") { resolver.setAll(.ours) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
                    .help("Garder notre version pour tous les blocs")
                Button("Tout : le leur") { resolver.setAll(.theirs) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
                    .help("Garder leur version pour tous les blocs")
            }
            Button(isManualEditing ? "Vue blocs" : "Éditer manuellement") {
                if !isManualEditing { manualText = file.rawContent() }
                isManualEditing.toggle()
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
            .help("Basculer entre la résolution par blocs et l'édition libre du fichier")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func hunksScroll(_ file: ConflictFile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(file.segments) { segment in
                    switch segment {
                    case .text(_, let lines):
                        contextBlock(lines)
                    case .conflict(_, let hunk):
                        conflictBlock(hunk)
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Contexte inchangé (borné pour ne pas noyer l'écran sur un gros fichier).
    private func contextBlock(_ lines: [String]) -> some View {
        let shown = Array(lines.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if lines.count > shown.count {
                Text("… \(lines.count - shown.count) ligne(s) de contexte")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func conflictBlock(_ hunk: ConflictHunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: hunk.choice == .unresolved ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(hunk.choice == .unresolved ? .orange : .green)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text("Conflit").font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            side(title: "Le nôtre · \(hunk.oursLabel)", lines: hunk.ours, tint: .green)
            side(title: "Le leur · \(hunk.theirsLabel)", lines: hunk.theirs, tint: .blue)
            HStack(spacing: 6) {
                choiceButton(hunk, .ours, "Le nôtre")
                choiceButton(hunk, .theirs, "Le leur")
                choiceButton(hunk, .oursThenTheirs, "Les deux")
                choiceButton(hunk, .theirsThenOurs, "Les deux (inversé)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hunk.choice == .unresolved ? Color.orange.opacity(0.4) : Color.green.opacity(0.4))
        )
    }

    private func side(title: String, lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.isEmpty {
                    Text("(vide)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.10)))
        }
    }

    private func choiceButton(_ hunk: ConflictHunk, _ choice: ConflictHunk.Choice, _ label: String) -> some View {
        let selected = hunk.choice == choice
        return Button {
            resolver.setChoice(choice, forHunk: hunk.id)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var manualEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $manualText)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Retire les marqueurs <<<<<<< ======= >>>>>>> à la main.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Enregistrer + marquer résolu") {
                    resolver.stageManual(manualText)
                    isManualEditing = false
                }
                .disabled(resolver.isBusy)
                .help("Écrit le fichier tel quel et le git add")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { resolver.abort() } label: {
                Label("Abandonner", systemImage: "xmark.circle")
            }
            .help("Abandonner l'opération et restaurer l'état initial du repo")
            .disabled(resolver.isBusy)

            Spacer(minLength: 8)

            if !isManualEditing, let file = resolver.current {
                Button("Marquer résolu + suivant") { resolver.stageResolved() }
                    .disabled(resolver.isBusy || !file.isFullyResolved)
                    .help("Écrit le fichier résolu, le git add, et passe au conflit suivant")
            }

            Button {
                resolver.continueOperation()
            } label: {
                Label("Continuer", systemImage: "arrow.right.circle.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(resolver.isBusy || !resolver.allStaged)
            .help("Poursuivre le rebase/merge (⌘↩) — actif quand tous les conflits sont stagés")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { resolver.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).help("Masquer").accessibilityLabel("Masquer le message")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
