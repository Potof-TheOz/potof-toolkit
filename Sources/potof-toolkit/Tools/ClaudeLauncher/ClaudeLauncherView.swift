import SwiftUI
import AppKit

/// Outil « Claude Launcher ».
///
/// Disposition en deux volets (`HSplitView`) :
/// - **Sidebar gauche** : sessions Claude en cours (haut) + un sélecteur
///   `Dossiers / Favoris` listant les dossiers d'où lancer une nouvelle session.
///   Les deux blocs sont séparés par un `VSplitView` : leur répartition en hauteur
///   se règle à la souris.
/// - **Centre** : le **terminal embarqué** de la session active (`claude` tourne
///   dans un PTY possédé par l'app). Fermer une session tue son process.
struct ClaudeLauncherView: View {
    /// Source unique de l'id de l'outil (réutilisée par `ToolRegistry` et par
    /// l'enregistrement auprès du coordinateur de notifications).
    static let toolID: Tool.ID = "claude-launcher"

    @AppStorage("rootPath") private var rootPath: String = ""
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var sessions = SessionStore()
    /// Sessions Claude passées (lecture des `.jsonl` de `~/.claude/projects`),
    /// limitées aux dossiers visibles. Reconstruites sur événements discrets.
    @StateObject private var previous = PreviousSessionsStore()

    @State private var subfolders: [FolderItem] = []
    /// Incrémenté à chaque `scan()` ; seul le scan le plus récent publie son résultat
    /// (garde contre les scans async concurrents terminant dans le désordre).
    @State private var scanGeneration = 0
    /// Favoris résolus (dossier existant + drapeau `CLAUDE.md`), reconstruits sur
    /// événements discrets (apparition, retour au premier plan, changement de favoris)
    /// et non à chaque rendu → pas d'accès disque par frame.
    @State private var favoriteFolders: [FolderItem] = []
    @State private var searchText: String = ""
    @State private var scope: FolderScope = .all
    /// Garde-fou : n'appliquer l'onglet par défaut (Favoris) qu'une fois, sans écraser
    /// un choix manuel ultérieur de l'utilisateur.
    @State private var didApplyDefaultScope = false
    /// Visibilité de la sidebar, mémorisée entre les lancements.
    @AppStorage("claudeLauncher.sidebarVisible") private var sidebarVisible: Bool = true
    /// Popover des sessions précédentes (ouvert depuis le bouton dédié).
    @State private var showingPrevious = false

    enum FolderScope: String, CaseIterable, Identifiable {
        case all = "Dossiers"
        case favorites = "Favoris"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            if sidebarVisible {
                sidebar
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
            center
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: sidebarVisible ? 760 : 460, minHeight: 480)
        .onAppear(perform: scan)
        // Ouvre sur l'onglet Favoris s'il existe au moins un favori (dossier encore
        // présent). Une seule fois, pour ne pas écraser un basculement manuel.
        .onAppear {
            loadFavorites()
            if !didApplyDefaultScope {
                didApplyDefaultScope = true
                if !favoriteFolders.isEmpty { scope = .favorites }
            }
            // `refreshPrevious` est déclenché par le scan du 1er onAppear (à sa complétion).
        }
        // Enregistre le store comme fournisseur de sessions pour le coordinateur de
        // notifications (mapping sid→session, focus, anti-spam). L'id de l'outil est
        // connu ici, pas dans SessionStore. Idempotent (dédup par identité).
        .onAppear {
            NotificationCenterCoordinator.shared.registerSessionProvider(sessions, toolID: Self.toolID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scan()          // rafraîchit les « précédentes » à sa complétion
            loadFavorites()
        }
        // Un (dé)favori change la liste : reconstruire (au lieu d'un stat par rendu).
        // `loadFavorites` rafraîchit déjà les « Précédentes ».
        .onChange(of: favorites.paths) { _ in loadFavorites() }
        // Une init « CLAUDE.md » vient d'être acceptée : le drapeau `hasClaudeMd` est figé
        // au scan → on rescanne pour cesser de proposer « Initialiser » sur ce dossier. Un
        // court délai laisse `claude` écrire le fichier après le « Yes » (le rescan lit le
        // disque) ; à défaut, le prochain retour au premier plan corrige de toute façon.
        .onReceive(NotificationCenter.default.publisher(for: .initClaudeMdDidWriteFile)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                scan()
                loadFavorites()
            }
        }
    }

    /// Bouton unique masquer/afficher la sidebar. Vit dans le centre (barre de
    /// session ou état vide) : toujours atteignable, y compris sidebar cachée.
    private func sidebarToggle() -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14, weight: .medium))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(sidebarVisible ? "Masquer la barre latérale (⌥⌘S)" : "Afficher la barre latérale (⌥⌘S)")
        .accessibilityLabel(sidebarVisible ? "Masquer la barre latérale" : "Afficher la barre latérale")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if sessions.sessions.isEmpty {
                folderPane
            } else {
                // Split vertical redimensionnable : la poignée entre les deux volets
                // permet de donner plus de place aux sessions ou aux dossiers, au besoin.
                VSplitView {
                    sessionsSection
                        .frame(minHeight: 88, idealHeight: 200, maxHeight: .infinity)
                    folderPane
                        .frame(minHeight: 200, maxHeight: .infinity)
                }
            }
            Divider()
            sidebarFooter
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    /// Volet bas de la sidebar : accès aux sessions précédentes + contrôles + liste
    /// des dossiers. Extrait pour servir tel quel (aucune session active) ou comme
    /// second volet du `VSplitView` (sessions actives présentes).
    private var folderPane: some View {
        VStack(spacing: 0) {
            if !previous.sessions.isEmpty {
                previousSessionsButton
                Divider()
            }
            folderControls
            Divider()
            folderList
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Sessions actives", systemImage: "terminal.fill",
                          tint: .green, count: sessions.sessions.count)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sessions.sessions) { session in
                        SessionRow(
                            session: session,
                            isActive: session.id == sessions.activeID,
                            onSelect: { sessions.reveal(session.id) },
                            onClose: { sessions.close(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            // Remplit le volet haut du VSplitView (la hauteur est fixée par la poignée,
            // plus par un plafond en dur).
            .frame(maxHeight: .infinity)
        }
    }

    /// Bouton d'accès aux sessions Claude passées des dossiers visibles. Ouvre une
    /// **popover** ; un clic sur une session la **reprend** (`claude --resume`) puis
    /// ferme la popover. Volontairement discret (« moins gênant » qu'une section
    /// permanente) et affiché seulement s'il y a au moins une session précédente.
    private var previousSessionsButton: some View {
        Button { showingPrevious = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Voir les sessions précédentes")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text("\(previous.sessions.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help("Afficher les sessions Claude précédentes des dossiers visibles")
        .accessibilityLabel("Voir les sessions précédentes (\(previous.sessions.count))")
        .popover(isPresented: $showingPrevious, arrowEdge: .trailing) {
            previousSessionsPopover
        }
    }

    /// Contenu de la popover : liste des sessions précédentes, la plus récente en
    /// haut. Clic sur une ligne → ferme la popover puis reprend la session.
    private var previousSessionsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Précédentes", systemImage: "clock.arrow.circlepath",
                          tint: .secondary, count: previous.sessions.count)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(previous.sessions) { session in
                        PreviousSessionRow(session: session) {
                            showingPrevious = false          // ferme la popover…
                            sessions.launch(folder: session.folderURL, resume: session.id)  // …puis reprend
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 340, height: min(CGFloat(previous.sessions.count) * 46 + 72, 460))
    }

    private var folderControls: some View {
        VStack(spacing: 10) {
            Picker("", selection: $scope) {
                ForEach(FolderScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            searchField
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            TextField("Rechercher", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Effacer la recherche")
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var folderList: some View {
        if rootPath.isEmpty {
            emptyRootPrompt
        } else if displayedFolders.isEmpty {
            emptyMessage(
                icon: searchText.isEmpty ? "tray" : "magnifyingglass",
                text: searchText.isEmpty
                    ? (scope == .favorites ? "Aucun favori." : "Aucun sous-dossier visible.")
                    : "Aucun résultat pour « \(searchText) »."
            )
        } else {
            // Le Set (résolution de liens symboliques par session) est calculé une
            // seule fois ici, pas une fois par ligne de dossier.
            folderScroll(running: runningFolderPaths)
        }
    }

    private func folderScroll(running: Set<String>) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(displayedFolders) { item in
                    FolderRow(
                        item: item,
                        isFavorite: favorites.isFavorite(item.url.path),
                        hasRunningSession: running.contains(SessionStore.normalized(item.url.path)),
                        onLaunch: { sessions.launch(folder: item.url) },
                        onToggleFavorite: { favorites.toggle(item.url.path) }
                    )
                    .contextMenu {
                        // Proposé seulement sur un vrai projet encore sans CLAUDE.md.
                        if item.isProjectCandidate && !item.hasClaudeMd {
                            Button {
                                sessions.launchInitializingClaudeMd(folder: item.url)
                            } label: {
                                Label("Initialiser CLAUDE.md…", systemImage: "sparkles")
                            }
                            Divider()
                        }
                        // Toujours présent → le menu n'est jamais vide, et les
                        // conventions maison restent éditables d'un clic droit.
                        Button {
                            NSWorkspace.shared.open(ConventionsProfile.ensureExists())
                        } label: {
                            Label("Éditer mes conventions…", systemImage: "slider.horizontal.3")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(rootPath.isEmpty ? "Aucun dossier racine" : (rootPath as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(rootPath.isEmpty ? "Aucun dossier racine sélectionné" : "Dossier racine : \(rootPath)")
                .accessibilityLabel(rootPath.isEmpty ? "Aucun dossier racine" : "Dossier racine \(rootPath)")
            Spacer(minLength: 4)
            Button(action: chooseFolder) {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.plain)
            .help("Changer de dossier racine (⌘O)")
            .accessibilityLabel("Changer de dossier racine")
            .keyboardShortcut("o", modifiers: .command)
            Button { scan() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Rafraîchir la liste des dossiers (⌘R)")
            .accessibilityLabel("Rafraîchir la liste des dossiers")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(rootPath.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Centre

    @ViewBuilder
    private var center: some View {
        if let session = sessions.activeSession {
            VStack(spacing: 0) {
                sessionBar(session)
                Divider()
                // Aperçu d'un diff proposé par Claude (openDiff) pour CETTE session.
                // On affiche le panneau **à la place** du terminal (pas en overlay) :
                // le terminal est un NSView (SwiftTerm) qui capterait les clics d'un
                // overlay SwiftUI posé au-dessus (fall-through du hit-test) → les
                // boutons paraîtraient morts. Le NSView reste vivant dans le
                // contrôleur (process + scrollback préservés) et revient au verdict.
                // Accepter → Claude écrit ; Refuser → fichier inchangé. Cf. IDE_BRIDGE.
                if let pres = sessions.pendingDiffs[session.id] {
                    DiffOverlayView(
                        request: pres.request,
                        diff: pres.diff,
                        onAccept: { sessions.resolveDiff(session.id, .saved) },
                        onReject: { sessions.resolveDiff(session.id, .rejected) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalHostView(controller: sessions.terminal, sessionID: session.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            centerEmptyState
        }
    }

    private func sessionBar(_ session: Session) -> some View {
        HStack(spacing: 10) {
            sidebarToggle()
            Divider().frame(height: 16)
            Image(systemName: "terminal.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderName)
                    .font(.system(size: 13, weight: .semibold))
                Text(session.folderURL.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(role: .destructive) {
                sessions.close(session.id)
            } label: {
                Label("Fermer la session", systemImage: "xmark.circle.fill")
            }
            .help("Ferme la session et arrête le process Claude")
            .accessibilityLabel("Fermer la session et arrêter Claude")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var centerEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Aucune session active")
                .font(.title3.weight(.semibold))
            Text(rootPath.isEmpty
                 ? "Choisissez un dossier racine, puis lancez Claude dans l'un de ses sous-dossiers."
                 : "Sélectionnez un dossier dans la barre latérale pour lancer Claude ici.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if rootPath.isEmpty {
                Button(action: chooseFolder) {
                    Label("Choisir un dossier", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(.background)
        .overlay(alignment: .topLeading) {
            sidebarToggle().padding(12)
        }
    }

    // MARK: - Petits éléments

    private func sectionHeader(title: String, systemImage: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.system(size: 12))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var emptyRootPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Choisissez un dossier racine")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
            Button(action: chooseFolder) { Text("Choisir…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyMessage(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Données dérivées

    private var displayedFolders: [FolderItem] {
        let base = scope == .favorites ? favoriteFolders : subfolders
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var runningFolderPaths: Set<String> { sessions.runningFolderPaths }

    // MARK: - Actions

    private func scan() {
        // Jeton de génération incrémenté à CHAQUE scan (y compris la branche racine vide) :
        // seul le résultat du scan le plus récent est publié. Robuste aux scans concurrents
        // (changement de racine OU deux scans même racine terminant dans le désordre) — un
        // simple `rootPath == token` ne suffisait pas pour le second cas.
        scanGeneration += 1
        let gen = scanGeneration
        guard !rootPath.isEmpty else {
            subfolders = []
            refreshPrevious()
            return
        }
        // L'énumération ET la construction des `FolderItem` (chacun fait un accès disque)
        // tournent **hors du thread principal** : multipliés par le nombre de sous-dossiers,
        // ils gèleraient la sidebar sur une grosse racine. C'est aussi ici — et pas chez
        // l'appelant — qu'on rafraîchit les « précédentes » (sinon calculées sur des
        // `subfolders` d'avant le scan).
        let rootURL = URL(fileURLWithPath: rootPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.scanFolders(at: rootURL)
            DispatchQueue.main.async {
                guard self.scanGeneration == gen else { return }   // un scan plus récent a pris la main
                self.subfolders = items
                self.refreshPrevious()
            }
        }
    }

    /// Énumère les sous-dossiers visibles et construit leurs `FolderItem`. **Statique et
    /// sans état** : conçu pour être appelé sur une file de fond (cf. `scan`).
    private static func scanFolders(at rootURL: URL) -> [FolderItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { url in
                guard !url.lastPathComponent.hasPrefix(".") else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
            }
            .map { FolderItem(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// (Re)construit la liste des favoris résolus. Appelé sur événements discrets
    /// (apparition, retour au premier plan, changement de favoris), jamais par rendu.
    /// Rafraîchit ensuite les « Précédentes » : au lancement racine vide, c'est le seul
    /// déclencheur qui voit des favoris peuplés (le scan racine-vide tourne avant).
    private func loadFavorites() {
        favoriteFolders = favorites.paths
            .compactMap { path -> FolderItem? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return FolderItem(url: URL(fileURLWithPath: path))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        refreshPrevious()
    }

    /// Rafraîchit la section « Précédentes » pour les dossiers visibles (sous-dossiers
    /// du root + favoris). Peu coûteux (cache `mtime`, parsing en tâche de fond).
    private func refreshPrevious() {
        previous.refresh(folders: subfolders + favoriteFolders)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choisissez le dossier racine"
        panel.prompt = "Choisir"
        if !rootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: rootPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
            searchText = ""
            subfolders = []   // vide TOUT DE SUITE : évite d'afficher les dossiers de l'ancienne racine pendant le scan async
            scan()            // rafraîchit les « précédentes » à sa complétion
        }
    }
}

// MARK: - Ligne de session

private struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Color.green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.folderName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.title != session.folderName && !session.title.isEmpty {
                    Text(session.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Fermer la session (arrête Claude)")
                .accessibilityLabel("Fermer la session « \(session.folderName) »")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(isActive
              ? "Session active « \(session.folderName) »"
              : "Afficher la session « \(session.folderName) » au centre")
    }
}

// MARK: - Ligne de session précédente

private struct PreviousSessionRow: View {
    let session: PreviousSession
    let onResume: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: hovering ? "play.circle.fill" : "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(session.folderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text(session.lastUsed, format: .relative(presentation: .named))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onResume)
        .onHover { hovering = $0 }
        .help("Reprendre « \(session.title) » dans « \(session.folderName) » (claude --resume)")
    }
}

// MARK: - Ligne de dossier

private struct FolderRow: View {
    let item: FolderItem
    let isFavorite: Bool
    let hasRunningSession: Bool
    let onLaunch: () -> Void
    let onToggleFavorite: () -> Void
    @State private var hovering = false

    /// Icône du dossier : marque Claude si un `CLAUDE.md` est présent à la racine,
    /// sinon l'icône dossier standard.
    @ViewBuilder
    private var folderIcon: some View {
        if item.hasClaudeMd {
            ClaudeMark()
                .frame(width: 15, height: 15)
                .help("Ce dossier contient un CLAUDE.md")
                .accessibilityHidden(true)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                folderIcon
                if hasRunningSession {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: -3, y: -3)
                        .help("Une session Claude tourne déjà dans ce dossier")
                        .accessibilityLabel("Session en cours")
                }
            }
            .frame(width: 20)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering || isFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavorite ? Color.yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
                .accessibilityLabel(isFavorite ? "Retirer « \(item.name) » des favoris" : "Ajouter « \(item.name) » aux favoris")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onLaunch)
        .onHover { hovering = $0 }
        .help(hasRunningSession
              ? "Lancer une nouvelle session Claude dans « \(item.name) » (une session y tourne déjà)"
              : "Lancer Claude dans « \(item.name) »")
    }
}
