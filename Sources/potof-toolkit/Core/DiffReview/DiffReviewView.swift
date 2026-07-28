import SwiftUI

/// **Corps de la fenêtre de revue** : ce que l'utilisateur lit et décide.
///
/// Une demande = un agent `claude` **bloqué** sur un appel `openDiff` (l'appel est
/// synchrone côté CLI). Toute la mise en page découle de ça : on montre *qui* attend,
/// *depuis quand*, *ce qu'il veut écrire*, et on offre trois issues — refuser,
/// accepter, accepter une version amendée.
///
/// La vue observe `DiffReviewCenter.shared` et `IDEContractGuard.shared` (singletons
/// app-level) : elle n'est **jamais** propriétaire de la file — la détruire (fermeture
/// de la fenêtre, changement d'outil) ne perd aucune demande, invariant du projet sur
/// l'état adossé à des process/connexions vivantes.
///
/// Elle ne rend **aucun** diff maison : tout passe par `Core/Diff` (`DiffLineRow`,
/// `DiffHalfRow`, `SideBySideDiff`, `DiffLayoutToggle`), exactement comme l'aperçu des
/// commits de Git Stuffs. Et elle **n'écrit jamais** sur disque : elle ne produit qu'un
/// verdict, c'est `claude` qui applique.
struct DiffReviewView: View {

    // MARK: - Sources de vérité (observées, jamais possédées)

    @ObservedObject private var center = DiffReviewCenter.shared
    /// Bandeau de dérive du contrat (rempli par T8) : on se contente de l'afficher.
    @ObservedObject private var contractGuard = IDEContractGuard.shared

    /// Disposition unifié / côte à côte. Clé propre à la revue : la préférence de
    /// Git Stuffs (`gitStuffs.diffLayoutMode`) répond à un autre usage, on ne la
    /// détourne pas.
    @AppStorage("diffReview.layoutMode") private var layoutMode: DiffLayoutMode = .unified

    /// Demande affichée. `nil` = « la plus ancienne » (repli naturel quand la sélection
    /// courante vient d'être résolue, ou fermée par `close_tab`).
    @State private var selectedID: UUID?

    /// Demandes dont le panneau central montre l'**éditeur** plutôt que le diff.
    /// L'état est gardé **par demande** : avec plusieurs agents en parallèle (cas
    /// nominal), passer de l'une à l'autre ne doit pas jeter un texte en cours d'édition.
    @State private var editing: Set<UUID> = []
    /// Contenu amendé par demande (absent = « on garde le contenu proposé »).
    @State private var edits: [UUID: String] = [:]
    /// Diff recalculé (contenu amendé vs **disque**) par demande, alimenté en débounce.
    @State private var editedDiffs: [UUID: FileDiff] = [:]
    /// Recalculs en attente, un par demande → une frappe dans A n'annule pas le
    /// recalcul de B.
    @State private var recomputeWork: [UUID: DispatchWorkItem] = [:]

    /// Informations dérivées du **disque**, pour la seule demande affichée.
    @State private var diskContext: DiskContext?

    /// Au-delà de ce nombre de lignes, `claude` scinde le hunk reconstruit et ne
    /// reprend que le **premier** (cf. `IDEProtocolContract.acceptedContent`) : accepter
    /// une version amendée y appliquerait une troncature silencieuse → édition coupée.
    private static let editableLineLimit = 100_000
    /// Débounce du recalcul de diff pendant la frappe (compromis réactivité / coût LCS).
    private static let recomputeDebounce = 0.2

    /// Ce qu'on a lu du fichier au moment d'afficher la demande.
    private struct DiskContext {
        let id: UUID
        /// Contenu sur disque : `""` si le fichier n'existe pas encore (création),
        /// `nil` s'il n'est pas décodable en UTF-8 (binaire) → comparaison impossible.
        let diskText: String?
        /// Max(lignes disque, lignes proposées) → confronté à `editableLineLimit`.
        let lineCount: Int
    }

    // MARK: - Corps

    var body: some View {
        VStack(spacing: 0) {
            if let warning = contractGuard.warning { driftBanner(warning) }
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncDiskContext)
        // La file bouge sans nous (résolution ailleurs, `close_tab`, client déconnecté) :
        // on nettoie l'état d'édition des demandes disparues, puis on resynchronise.
        .onChange(of: center.pending.map(\.id)) { ids in
            prune(to: ids)
            syncDiskContext()
        }
        .onChange(of: selectedID) { _ in syncDiskContext() }
    }

    @ViewBuilder
    private var content: some View {
        if let item = selected {
            // File d'attente : liste latérale seulement à partir de 2 demandes. À une
            // seule, une colonne vide serait du bruit → plein cadre.
            if center.pending.count >= 2 {
                HSplitView {
                    queueList
                        .frame(minWidth: 190, idealWidth: 250, maxWidth: 380)
                    detail(item)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                detail(item)
            }
        } else {
            idleState
        }
    }

    /// Demande affichée : la sélection explicite si elle est encore en vie, sinon la
    /// plus ancienne (celle dont l'agent attend depuis le plus longtemps).
    private var selected: PendingDiffReview? {
        if let selectedID, let item = center.pending.first(where: { $0.id == selectedID }) {
            return item
        }
        return center.pending.first
    }

    // MARK: - Bandeau de dérive du contrat

    /// Le pont IDE repose sur un protocole non documenté : quand `IDEContractGuard`
    /// constate qu'une acceptation n'a **pas** été appliquée, il faut le dire fort —
    /// le mode d'échec silencieux (« j'ai cliqué Accepter et rien ne s'est écrit »)
    /// est précisément celui qu'on veut rendre impossible.
    private func driftBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(warning)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button { contractGuard.clear() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Masquer l'avertissement")
            .accessibilityLabel("Masquer l'avertissement")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - File d'attente

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text("\(center.pending.count) agents en attente")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(center.pending) { queueRow($0) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func queueRow(_ item: PendingDiffReview) -> some View {
        let isSelected = item.id == selected?.id
        return Button { selectedID = item.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.origin.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileName(item))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    PendingAgeLabel(receivedAt: item.receivedAt, compact: true)
                }
                Spacer(minLength: 4)
                if isEdited(item) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                        .help("Contenu amendé, pas encore accepté")
                        .accessibilityLabel("Contenu amendé")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.request.oldPath)
        .accessibilityLabel("\(item.origin.label) — \(fileName(item))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Détail d'une demande

    private func detail(_ item: PendingDiffReview) -> some View {
        let diff = shownDiff(item)
        return VStack(spacing: 0) {
            header(item, diff: diff)
            Divider()
            if let note = editingBlockedNote { noteRow(note, icon: "exclamationmark.triangle") }
            centerPane(item, diff: diff)
            Divider()
            footer(item, diff: diff)
        }
    }

    /// Diff à afficher : celui recalculé si l'utilisateur a amendé le contenu (il fait
    /// alors autorité — c'est ce que `claude` recevra), sinon celui calculé à la
    /// réception. Le repli sur `item.diff` couvre les ~200 ms de débounce.
    private func shownDiff(_ item: PendingDiffReview) -> FileDiff {
        guard isEdited(item) else { return item.diff }
        return editedDiffs[item.id] ?? item.diff
    }

    // MARK: En-tête

    private func header(_ item: PendingDiffReview, diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(item.origin.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("propose une modification")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                PendingAgeLabel(receivedAt: item.receivedAt)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                Image(systemName: diff.isNewFile ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName(item))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Chemin complet tronqué **au milieu** : sous Superset les chemins
                    // sont longs et c'est la fin (le fichier) qui identifie.
                    Text(item.request.oldPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.request.oldPath)
                }

                Spacer(minLength: 12)
                badges(diff)
                if !isEditing(item) { DiffLayoutToggle(mode: $layoutMode) }
                editToggle(item)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func badges(_ diff: FileDiff) -> some View {
        HStack(spacing: 6) {
            if diff.isNewFile {
                badge(text: "Nouveau fichier", systemImage: "plus.circle", color: .accentColor)
                    .accessibilityLabel("Nouveau fichier")
            }
            if diff.isBinary {
                badge(text: "Binaire", systemImage: "doc.badge.ellipsis", color: .orange)
                    .accessibilityLabel("Fichier binaire")
            }
            badge(text: "+\(diff.addedCount)", color: .green)
                .accessibilityLabel("\(diff.addedCount) lignes ajoutées")
            badge(text: "−\(diff.removedCount)", color: .red)
                .accessibilityLabel("\(diff.removedCount) lignes supprimées")
        }
    }

    private func badge(text: String, systemImage: String? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    /// Bascule « voir le diff » ⇄ « éditer le contenu ». Désactivée quand le fichier
    /// dépasse le seuil du protocole (l'explication est affichée sous l'en-tête, un
    /// bouton désactivé n'affiche pas son infobulle de façon fiable).
    private func editToggle(_ item: PendingDiffReview) -> some View {
        let editingNow = isEditing(item)
        let label = editingNow ? "Voir le diff" : "Éditer"
        let icon = editingNow ? "list.bullet.rectangle" : "square.and.pencil"
        return Button {
            setEditing(!editingNow, for: item)
        } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!editingNow && editingBlockedNote != nil)
        .help(editingNow
              ? "Revenir au diff (les modifications sont conservées)"
              : "Amender le contenu avant de l'accepter — Claude écrira la version affichée")
        .accessibilityLabel(label)
    }

    /// Raison de l'interdiction d'éditer, `nil` si l'édition est permise. Le disque
    /// n'est pas encore lu ⇒ on n'interdit pas (la lecture est quasi instantanée et le
    /// bouton ne doit pas clignoter).
    private var editingBlockedNote: String? {
        guard let ctx = diskContext, ctx.lineCount > Self.editableLineLimit else { return nil }
        return "Fichier de \(ctx.lineCount) lignes : au-delà de \(Self.editableLineLimit), "
             + "claude scinde le diff en plusieurs blocs et ne reprend que le premier. "
             + "L'édition est désactivée pour ne pas appliquer une version tronquée — "
             + "accepter ou refuser reste possible."
    }

    // MARK: Panneau central

    @ViewBuilder
    private func centerPane(_ item: PendingDiffReview, diff: FileDiff) -> some View {
        if isEditing(item) {
            // L'éditeur **remplace** le diff (décision produit) : deux rendus de gros
            // fichiers côte à côte ne tiennent pas dans une fenêtre flottante, et le
            // diff amendé reste lisible d'un clic sur « Voir le diff ».
            DiffEditorView(text: editBinding(item), isEditable: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else if diff.isBinary {
            // Le fichier d'origine n'est pas décodable en UTF-8 : aucun aperçu
            // ligne-à-ligne possible, mais on garde le pied d'action (l'agent attend
            // quand même une réponse).
            emptyState(icon: "doc.badge.ellipsis",
                       text: "Fichier binaire — aperçu indisponible.")
        } else if diff.lines.isEmpty {
            emptyState(icon: "equal.circle",
                       text: "Aucune différence à afficher.")
        } else {
            diffScroll(diff)
        }
    }

    /// Rendu du diff, **strictement** avec les composants de `Core/Diff`.
    ///
    /// `LazyVStack` dans les deux modes : un `openDiff` porte le fichier **entier**,
    /// donc potentiellement des dizaines de milliers de lignes — un `VStack` eager
    /// figerait la fenêtre à l'ouverture. (Git Stuffs se permet l'eager en côte à côte
    /// parce que ses diffs y sont repliés autour des hunks, donc bornés ; ici ils ne
    /// le sont pas.) `.id(layoutMode)` force une reconstruction propre à la bascule.
    private func diffScroll(_ diff: FileDiff) -> some View {
        ScrollView(.vertical) {
            Group {
                if layoutMode == .sideBySide {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(SideBySideDiff.pair(diff.lines)) { row in
                            HStack(alignment: .top, spacing: 0) {
                                DiffHalfRow(line: row.left, side: .old)
                                Divider()
                                DiffHalfRow(line: row.right, side: .new)
                            }
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            DiffLineRow(line: line)
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

    // MARK: Pied d'action

    private func footer(_ item: PendingDiffReview, diff: FileDiff) -> some View {
        let noOp = isNoOp(item, diff: diff)
        return VStack(alignment: .leading, spacing: 8) {
            if noOp { noteRow(Self.noOpNote, icon: "exclamationmark.triangle") }

            HStack(spacing: 12) {
                // Libellés honnêtes : on ne laisse pas croire que l'app écrit quoi que
                // ce soit — c'est `claude` qui applique, avec le contenu qu'on renvoie.
                Text(isEdited(item)
                     ? "Claude appliquera la version affichée ici."
                     : "Claude appliquera cette modification.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button("Refuser") { reject(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .help("Refuser — le fichier reste inchangé")
                    .accessibilityLabel("Refuser — le fichier reste inchangé")

                Button(isEdited(item) ? "Accepter les modifications" : "Accepter") {
                    accept(item)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help(noOp
                      ? "Le contenu est identique au fichier sur disque : Claude traitera cette acceptation comme un refus"
                      : "Accepter — Claude appliquera cette modification")
                .accessibilityLabel(isEdited(item)
                                    ? "Accepter les modifications — Claude appliquera la version affichée"
                                    : "Accepter — Claude appliquera cette modification")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// ⚠️ Fait protocolaire (§2.3 du plan, `IDEProtocolContract`) : le CLI recalcule un
    /// diff `disque → contenu renvoyé`. S'il est vide, il n'y a **aucun hunk** et
    /// `claude` en déduit « refusé par l'utilisateur ». Il faut donc le dire avant le
    /// clic, sinon l'utilisateur croit accepter alors qu'il annule.
    private static let noOpNote =
        "Le contenu est identique au fichier sur disque : Claude n'y verra aucune "
        + "modification et traitera l'acceptation comme un refus."

    private func noteRow(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - États vides

    private var idleState: some View {
        emptyState(icon: "checkmark.circle",
                   text: "Aucune modification en attente de validation.")
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Verdicts

    private func accept(_ item: PendingDiffReview) {
        // Toujours le contenu **courant** : identique au proposé tant que rien n'a été
        // amendé, donc un seul chemin de code (et pas de « j'ai édité puis rebasculé
        // en vue diff, mes modifications ont été perdues »).
        center.resolve(item.id, .saved(content: currentContent(item)))
        forget(item.id)
    }

    private func reject(_ item: PendingDiffReview) {
        center.resolve(item.id, .rejected)
        forget(item.id)
    }

    // MARK: - Édition

    private func isEditing(_ item: PendingDiffReview) -> Bool { editing.contains(item.id) }

    /// `true` dès que le contenu diverge de ce que l'agent a proposé.
    private func isEdited(_ item: PendingDiffReview) -> Bool {
        guard let text = edits[item.id] else { return false }
        return text != item.request.newContents
    }

    private func currentContent(_ item: PendingDiffReview) -> String {
        edits[item.id] ?? item.request.newContents
    }

    private func setEditing(_ on: Bool, for item: PendingDiffReview) {
        if on {
            // On matérialise le contenu à la première entrée en édition : l'éditeur a
            // besoin d'un binding stable, et `isEdited` reste faux tant que rien n'a
            // réellement changé (comparaison au contenu proposé).
            if edits[item.id] == nil { edits[item.id] = item.request.newContents }
            editing.insert(item.id)
        } else {
            editing.remove(item.id)
        }
    }

    /// Binding consommé par `DiffEditorView`. C'est **ici** que vit le débounce : la
    /// vue d'édition n'a pas à connaître le diff (elle ne fait qu'éditer du texte).
    private func editBinding(_ item: PendingDiffReview) -> Binding<String> {
        Binding(
            get: { edits[item.id] ?? item.request.newContents },
            set: { newValue in
                edits[item.id] = newValue
                // On passe la valeur explicitement : relire `edits` juste après
                // l'écriture n'est pas garanti dans le même tour de boucle.
                scheduleRecompute(item, content: newValue)
            })
    }

    /// Recalcule le diff « **disque** → contenu amendé » après ~200 ms sans frappe.
    /// Le calcul (lecture disque + LCS) part sur une file de fond : sur un gros fichier
    /// il coûte trop cher pour le thread principal. Le résultat est rangé **par id**,
    /// donc jamais attribué à la mauvaise demande même si la sélection a changé entre
    /// temps.
    private func scheduleRecompute(_ item: PendingDiffReview, content: String) {
        recomputeWork[item.id]?.cancel()
        let id = item.id
        let path = item.request.oldPath
        let work = DispatchWorkItem {
            let diff = DiffComputer.compute(oldPath: path, newContent: content)
            DispatchQueue.main.async { editedDiffs[id] = diff }
        }
        recomputeWork[id] = work
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + Self.recomputeDebounce, execute: work)
    }

    /// Le contenu qu'on s'apprête à renvoyer est-il indiscernable du fichier sur disque ?
    ///
    /// Test **exact** (octet à octet) quand on a pu lire le disque : le comptage de
    /// lignes du diff ne suffit pas (un `\n` final ajouté ou retiré ne produit aucune
    /// ligne ajoutée/supprimée alors que le CLI, lui, verra un hunk). Repli sur les
    /// compteurs quand le fichier n'est pas lisible en texte.
    private func isNoOp(_ item: PendingDiffReview, diff: FileDiff) -> Bool {
        if let ctx = diskContext, ctx.id == item.id, let disk = ctx.diskText {
            return currentContent(item) == disk
        }
        return !diff.isBinary && diff.addedCount == 0 && diff.removedCount == 0
    }

    // MARK: - Contexte disque

    /// (Re)lit le fichier de la demande affichée : contenu de référence pour la
    /// détection « acceptation équivalente à un refus », et taille pour le seuil
    /// d'édition. Une lecture par demande affichée, jamais sur le thread principal.
    private func syncDiskContext() {
        guard let item = selected else { diskContext = nil; return }
        guard diskContext?.id != item.id else { return }
        diskContext = nil
        let id = item.id
        let path = item.request.oldPath
        let proposed = item.request.newContents
        DispatchQueue.global(qos: .userInitiated).async {
            let disk = Self.readText(path)
            let lines = max(Self.lineCount(disk ?? ""), Self.lineCount(proposed))
            let ctx = DiskContext(id: id, diskText: disk, lineCount: lines)
            DispatchQueue.main.async {
                // La sélection a pu changer pendant la lecture : on ne colle pas un
                // contexte périmé sur une autre demande.
                guard selected?.id == id else { return }
                diskContext = ctx
            }
        }
    }

    /// Contenu texte du fichier : `""` s'il n'existe pas (création), `nil` s'il n'est
    /// pas décodable en UTF-8 (binaire) — même convention que `DiffComputer`.
    private static func readText(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return "" }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Comptage de lignes en une passe sur les octets UTF-8 : pas de découpage ni
    /// d'allocation, on peut se le permettre sur un fichier de plusieurs mégaoctets.
    private static func lineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var n = 1
        for byte in s.utf8 where byte == 0x0A { n += 1 }
        return n
    }

    // MARK: - Ménage

    /// Oublie tout l'état local attaché à une demande résolue.
    private func forget(_ id: UUID) {
        recomputeWork[id]?.cancel()
        recomputeWork[id] = nil
        edits[id] = nil
        editedDiffs[id] = nil
        editing.remove(id)
        if selectedID == id { selectedID = nil }
    }

    /// Même ménage, mais piloté par la file : une demande peut disparaître sans clic
    /// (fermeture d'onglet côté `claude`, client déconnecté).
    private func prune(to ids: [UUID]) {
        let live = Set(ids)
        for (id, work) in recomputeWork where !live.contains(id) { work.cancel() }
        recomputeWork = recomputeWork.filter { live.contains($0.key) }
        edits = edits.filter { live.contains($0.key) }
        editedDiffs = editedDiffs.filter { live.contains($0.key) }
        editing = editing.intersection(live)
        if let selectedID, !live.contains(selectedID) { self.selectedID = nil }
    }

    private func fileName(_ item: PendingDiffReview) -> String {
        (item.request.oldPath as NSString).lastPathComponent
    }
}

/// Ancienneté d'une demande, **qui s'incrémente toute seule**.
///
/// Ce n'est pas cosmétique : `openDiff` est un appel bloquant, l'agent est figé tant
/// qu'on n'a pas tranché. Voir « 4 min » plutôt qu'un horodatage rend l'attente
/// tangible (et le passage à l'orange signale un agent oublié).
///
/// Vue **à part** avec son propre `TimelineView` : sans ça, le tic-tac reconstruirait
/// tout le panneau chaque seconde — donc réapparierait le diff côte à côte d'un fichier
/// entier, une fois par seconde.
private struct PendingAgeLabel: View {
    let receivedAt: Date
    var compact: Bool = false

    private static let staleAfter = 120

    var body: some View {
        TimelineView(.periodic(from: receivedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(receivedAt)))
            let text = Self.format(seconds)
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: compact ? 9 : 11))
                    .accessibilityHidden(true)
                Text(compact ? text : "en attente depuis \(text)")
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(seconds >= Self.staleAfter ? Color.orange : Color.secondary)
            .help("L'agent est bloqué sur cette demande depuis \(text) : il attend la décision.")
            .accessibilityLabel("En attente depuis \(text)")
        }
    }

    private static func format(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 {
            let rest = seconds % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
