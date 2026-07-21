import SwiftUI

/// Panneau du rebase interactif : construction du plan, exécution réelle, puis
/// gestion des états de pause (edit / conflit) et de fin.
///
/// Présenté **en place** dans la zone centrale (pas en feuille) : une `.sheet` macOS
/// n'est pas redimensionnable, alors qu'inline le panneau remplit la fenêtre (elle,
/// redimensionnable) et son split interne s'ajuste. `onClose` revient au graphe.
struct RebasePanelView: View {
    @ObservedObject var controller: RebaseController
    let onClose: () -> Void
    @State private var showingConfirm = false
    @State private var showingPushConfirm = false
    /// Étape (commit) dont le diff est affiché à droite du plan. Défaut : le plus récent.
    @State private var selectedStepID: String?

    var body: some View {
        VStack(spacing: 0) {
            switch controller.phase {
            case .editing:  editing
            case .running:  running
            case .paused:   paused
            case .finished: finished
            case .failed:   failed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - En-tête générique

    private func header(_ title: String, systemImage: String, tint: Color = .accentColor) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Édition du plan

    private var editing: some View {
        VStack(spacing: 0) {
            header("Rebase interactif", systemImage: "arrow.triangle.2.circlepath")
            Divider()
            if !controller.treeClean {
                dirtyBanner
                Divider()
            }
            // Plan à gauche, diff du commit sélectionné à droite.
            HSplitView {
                stepsList
                    .frame(minWidth: 340, idealWidth: 500)
                rebaseDiffPane
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            if let error = controller.validationError {
                Divider()
                validationBanner(error)
            }
            Divider()
            editingFooter
        }
        .onAppear {
            // Sélectionne le commit le plus récent (dernière ligne du plan) par défaut.
            if selectedStepID == nil { selectedStepID = controller.steps.last?.id }
        }
        .alert("Réécrire l'historique ?", isPresented: $showingConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Lancer le rebase", role: .destructive) { controller.launch() }
        } message: {
            Text("Le rebase modifie les commits de la branche courante (réécriture d'historique locale). Aucun push ni --force n'est effectué. Continuer ?")
        }
    }

    /// Diff (arbre + contenu) du commit sélectionné dans le plan, à droite du rebase.
    @ViewBuilder
    private var rebaseDiffPane: some View {
        if let id = selectedStepID, let step = controller.steps.first(where: { $0.id == id }) {
            CommitDiffView(
                target: CommitDiffTarget(repo: controller.repoURL, hash: step.id,
                                         shortHash: step.shortHash, subject: step.originalSubject),
                onClose: nil
            )
            .id(step.id)      // recharge le diff quand on change de commit
        } else {
            Text("Sélectionnez un commit du plan pour voir son diff.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dirtyBanner: some View {
        let entries = Git.describeStatus(controller.dirtyStatus)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(entries.isEmpty
                     ? "Arbre de travail non propre — commitez ou remisez avant de rebaser."
                     : "Arbre de travail non propre : \(entries.count) élément\(entries.count > 1 ? "s" : "") à committer ou remiser avant de rebaser.")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button { controller.refreshCleanState() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Revérifier l'état de l'arbre")
                .accessibilityLabel("Revérifier l'état de l'arbre")
            }
            if !entries.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .frame(width: 130, alignment: .leading)
                                Text(entry.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    private func validationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(controller.steps.count) commit\(controller.steps.count > 1 ? "s" : "") — du plus ancien (haut) au plus récent (bas).")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            Text("Glissez pour réordonner. « squash »/« fixup » fusionnent avec la ligne au-dessus.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            List {
                ForEach($controller.steps) { $step in
                    RebaseStepRow(
                        step: $step,
                        isSelected: step.id == selectedStepID,
                        onSelect: { selectedStepID = step.id }
                    )
                }
                .onMove { controller.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
        }
        .frame(maxHeight: .infinity)
    }

    private var editingFooter: some View {
        HStack {
            Button("Annuler") { onClose() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Lancer le rebase") { showingConfirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.treeClean || controller.validationError != nil)
                .help(controller.treeClean ? "Exécuter le rebase" : "Arbre non propre : lancement bloqué")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - En cours

    private var running: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("git travaille…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - En pause (edit / conflit)

    private var paused: some View {
        VStack(spacing: 0) {
            header(controller.hasConflicts ? "Conflit pendant le rebase" : "Rebase en pause",
                   systemImage: controller.hasConflicts ? "exclamationmark.triangle.fill" : "pause.circle.fill",
                   tint: .orange)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.hasConflicts
                     ? "Des conflits sont à résoudre dans le repo (dans votre éditeur habituel), puis « git add » les fichiers résolus. Vous pourrez alors continuer, ou tout abandonner sans risque."
                     : "Le rebase s'est arrêté sur un commit « edit ». Faites vos modifications dans le repo si besoin, puis continuez — ou abandonnez pour tout restaurer.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                outputBox
            }
            .padding(16)
            Divider()
            HStack {
                Button("Abandonner le rebase", role: .destructive) { controller.abortRebase() }
                    .help("git rebase --abort : restaure le repo à son état initial")
                Spacer()
                Button("Continuer") { controller.continueRebase() }
                    .buttonStyle(.borderedProminent)
                    .help("git rebase --continue")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Terminé

    private var finished: some View {
        VStack(spacing: 0) {
            header("Rebase terminé", systemImage: "checkmark.circle.fill", tint: .green)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.resultMessage)
                    .font(.system(size: 13, weight: .medium))
                if !controller.output.isEmpty {
                    outputBox
                }
                if controller.completed, let upstream = controller.upstream {
                    Divider()
                    pushSection(upstream)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("Fermer") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .alert("Forcer la mise à jour de la branche distante ?", isPresented: $showingPushConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Pousser (force-with-lease)", role: .destructive) { controller.forcePush() }
        } message: {
            Text("Le rebase a réécrit l'historique local. Le pousser réécrit aussi l'historique de la branche distante (\(controller.upstream ?? "")). « --force-with-lease » refuse d'écraser si l'amont a bougé de façon inattendue. Continuer ?")
        }
    }

    /// Section de synchronisation distante après un rebase réussi : force-push encadré.
    @ViewBuilder
    private func pushSection(_ upstream: String) -> some View {
        if controller.isPushing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Push en cours…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let result = controller.pushResult {
            HStack(spacing: 8) {
                Image(systemName: controller.pushOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(controller.pushOK ? .green : .red)
                    .accessibilityHidden(true)
                Text(result)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("La branche locale diverge maintenant de l'amont. Mettre à jour la branche distante ?")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    showingPushConfirm = true
                } label: {
                    Label("Pousser vers \(upstream) (force-with-lease)", systemImage: "arrow.up.forward.circle")
                }
                .help("git push --force-with-lease vers \(upstream) — réécrit la branche distante en sécurité")
            }
        }
    }

    // MARK: - Échec

    private var failed: some View {
        VStack(spacing: 0) {
            header("Le rebase a échoué", systemImage: "xmark.octagon.fill", tint: .red)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("git a signalé une erreur. Le repo n'est pas en cours de rebase (aucune modification laissée en suspens).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                outputBox
            }
            .padding(16)
            Divider()
            HStack {
                Button("Revenir au plan") { controller.backToEditing() }
                Spacer()
                Button("Fermer") { onClose() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Éléments partagés

    private var outputBox: some View {
        ScrollView {
            Text(controller.output.isEmpty ? "(aucune sortie)" : controller.output)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Ligne du plan de rebase

private struct RebaseStepRow: View {
    @Binding var step: RebaseStep
    /// Ligne sélectionnée (son diff est affiché à droite).
    let isSelected: Bool
    /// Sélectionne ce commit → met à jour le diff à droite.
    let onSelect: () -> Void

    /// Fusion (squash/fixup) : la ligne est **imbriquée** sous le commit du dessus.
    private var isMeld: Bool { step.action.isMeld }
    /// Suppression : la ligne est marquée en rouge (le commit disparaît).
    private var isDrop: Bool { step.action == .drop }

    /// Teinte de mise en avant de la ligne (fusion = accent, suppression = rouge).
    private var accent: Color? {
        if isDrop { return .red }
        if isMeld { return .accentColor }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Glissez pour réordonner")
                    .accessibilityHidden(true)

                // Connecteur d'imbrication : la fusion se rattache au commit au-dessus.
                if isMeld {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .help(step.action == .fixup
                              ? "Fusionné dans le commit au-dessus — message de CE commit ignoré"
                              : "Fusionné dans le commit au-dessus — messages combinés")
                        .accessibilityLabel("Fusionné dans le commit au-dessus")
                } else if isDrop {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .help("Ce commit sera supprimé de l'historique")
                        .accessibilityLabel("Commit supprimé")
                }

                Picker("", selection: $step.action) {
                    ForEach(RebaseAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Action de rebase appliquée à ce commit")

                // Zone cliquable (hash + sujet) : sélectionne le commit pour le diff.
                HStack(spacing: 10) {
                    Text(step.shortHash)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isDrop ? Color.red.opacity(0.8) : Color.accentColor)

                    Text(step.originalSubject)
                        .font(.system(size: 12))
                        .foregroundStyle(isDrop ? Color.red : .primary)
                        .strikethrough(isDrop)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

                Button(action: onSelect) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Voir le diff de ce commit (à droite)")
                .accessibilityLabel("Voir le diff du commit \(step.shortHash)")
            }

            if step.action == .reword {
                TextField("Nouveau message", text: $step.newMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
        // Décalage vers la droite : rend l'imbrication de la fusion visible.
        .padding(.leading, isMeld ? 26 : 0)
        .overlay(alignment: .leading) {
            // Liseré coloré : accent (fusion) ou rouge (suppression).
            if let accent {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(0.6))
                    .frame(width: 2)
                    .padding(.vertical, 2)
                    .padding(.leading, isMeld ? 8 : 0)
            }
        }
        .background((accent ?? .clear).opacity(accent == nil ? 0 : 0.06))
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}
