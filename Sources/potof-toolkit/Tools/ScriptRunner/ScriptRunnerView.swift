import SwiftUI
import AppKit

/// Outil « Script Runner ».
///
/// Disposition en deux volets (`HSplitView`, jamais `NavigationSplitView`) :
/// - **Sidebar gauche** : section « Exécutions » (runs en cours/terminés) au-dessus
///   de la liste filtrable des projets (package.json racine + workspaces en
///   sous-entrées), séparées par un `VSplitView` redimensionnable.
/// - **Centre** : selon la sélection — le terminal d'un run (header : script,
///   statut, Stop/Fermer) ou le détail d'un package (scripts + boutons ▶).
///
/// L'état process-backed (runs, terminaux, sélection) vit dans
/// `ScriptRunStore.shared` / `ScriptTerminalController.shared` : il **survit au
/// changement d'outil** (la vue n'est qu'une projection jetable).
struct ScriptRunnerView: View {
    /// Id de l'outil (référencé par `ToolRegistry`).
    static let toolID: Tool.ID = "script-runner"

    @ObservedObject private var runs = ScriptRunStore.shared
    /// `@ObservedObject` sur le singleton (PAS `@StateObject`) : le scan de `$HOME`
    /// doit survivre au switch d'outil (`RootView` détruit la vue). Cf. PackageStore.
    @ObservedObject private var packages = PackageStore.shared
    /// Le scan de `$HOME` n'est automatique qu'au tout 1er lancement ; ensuite on
    /// lit le cache (le bouton Rafraîchir relance un scan à la demande).
    @AppStorage("scriptRunner.didScanOnce") private var didScanOnce = false

    /// Filtre de la liste des projets (nom + chemin). État jetable : perdu au
    /// switch d'outil, contrairement à la sélection (qui vit dans le store).
    @State private var searchText = ""
    /// Projets (monorepos) dont les workspaces sont dépliés (clé = `PackageProject.id`).
    @State private var expanded: Set<String> = []

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            center
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 500)
        .onAppear {
            if !didScanOnce {
                didScanOnce = true
                packages.scan()
            }
            // La sélection survit au switch d'outil, pas `expanded` : si un
            // sous-package est sélectionné, redéplier son projet pour que la
            // ligne surlignée reste visible dans la sidebar.
            revealSelectedSubpackage()
        }
        // Sélectionner un sous-package hors onAppear (ex. `close()` d'un run bascule
        // sur `.package(...)` d'un workspace replié) doit aussi le révéler.
        .onChange(of: runs.selection) { _ in revealSelectedSubpackage() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if runs.runs.isEmpty {
                projectsPane
            } else {
                // Split vertical redimensionnable : la poignée entre les deux volets
                // permet de donner plus de place aux exécutions ou aux projets.
                VSplitView {
                    runsSection
                        .frame(minHeight: 88, idealHeight: 200, maxHeight: .infinity)
                    projectsPane
                        .frame(minHeight: 200, maxHeight: .infinity)
                }
            }
            Divider()
            sidebarFooter
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    // MARK: Section « Exécutions »

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Exécutions", systemImage: "play.circle.fill",
                          tint: .green, count: runs.runs.count)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(runs.runs) { run in
                        RunRow(
                            run: run,
                            isSelected: runs.selection == .run(run.id),
                            onSelect: { runs.focus(run.id) },
                            onClose: { runs.close(run.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            // Remplit le volet haut du VSplitView (la hauteur est fixée par la
            // poignée, pas par un plafond en dur).
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Volet projets

    /// Volet bas de la sidebar : filtre + liste des projets. Extrait pour servir
    /// tel quel (aucun run) ou comme second volet du `VSplitView`.
    private var projectsPane: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)
            Divider()
            projectList
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            TextField("Filtrer par nom ou chemin", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Effacer le filtre")
                .accessibilityLabel("Effacer le filtre")
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
    private var projectList: some View {
        if packages.projects.isEmpty {
            emptyProjects
        } else if displayedProjects.isEmpty {
            emptyMessage(icon: "magnifyingglass", text: "Aucun projet pour « \(searchText) ».")
        } else {
            // Le Set des packages ayant un run actif est calculé une seule fois
            // ici, pas une fois par ligne.
            projectScroll(activeDirs: activeRunDirs)
        }
    }

    private func projectScroll(activeDirs: Set<String>) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(displayedProjects) { project in
                    ProjectRow(
                        project: project,
                        isSelected: runs.selection == .package(project.id),
                        isExpanded: isExpanded(project),
                        hasActiveRun: activeDirs.contains(project.root.path)
                            || project.subpackages.contains { activeDirs.contains($0.path) },
                        onSelect: { runs.selection = .package(project.id) },
                        onToggleExpand: { toggleExpanded(project) }
                    )
                    if isExpanded(project) {
                        ForEach(displayedSubpackages(of: project)) { sub in
                            SubpackageRow(
                                package: sub,
                                projectRoot: project.root.dir,
                                isSelected: runs.selection == .package(sub.id),
                                hasActiveRun: activeDirs.contains(sub.path),
                                onSelect: { runs.selection = .package(sub.id) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyProjects: some View {
        if packages.isScanning {
            emptyMessage(icon: "hourglass", text: "Recherche des package.json…")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cube")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucun package.json trouvé")
                    .font(.system(size: 12, weight: .medium))
                Button { packages.scan() } label: { Text("Lancer un scan…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if packages.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scan… \(packages.foundSoFar) package\(packages.foundSoFar > 1 ? "s" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Image(systemName: "cube.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text("\(packages.projects.count) projet\(packages.projects.count > 1 ? "s" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Button { packages.scan() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(packages.isScanning)
            .help("Re-scanner le disque à la recherche de package.json (⌘R)")
            .accessibilityLabel("Rafraîchir la liste des projets")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Centre

    @ViewBuilder
    private var center: some View {
        // ⚠️ La sélection vit dans le singleton et peut référencer un run fermé ou
        // un package disparu au re-scan : toute résolution ratée retombe sur
        // l'état vide, jamais sur un crash.
        switch runs.selection {
        case .run(let id):
            if let run = runs.runs.first(where: { $0.id == id }) {
                runDetail(run)
            } else {
                centerEmptyState
            }
        case .package:
            if let ctx = selectedPackageContext {
                PackageDetailView(package: ctx.package,
                                  projectRoot: ctx.projectRoot,
                                  projectName: ctx.projectName)
                    // État frais (relecture manifest + re-détection manager) par
                    // package ET par racine : un re-scan peut re-grouper le package
                    // sous une nouvelle racine (lockfile différent) sans changer son
                    // chemin — inclure `projectRoot` force alors un `reload`.
                    .id("\(ctx.package.id)|\(ctx.projectRoot.path)")
            } else {
                centerEmptyState
            }
        case nil:
            centerEmptyState
        }
    }

    private func runDetail(_ run: ScriptRun) -> some View {
        VStack(spacing: 0) {
            runBar(run)
            Divider()
            TerminalHostView(terminal: runs.terminal.view(for: run.id), focusID: run.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runBar(_ run: ScriptRun) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(run.status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.scriptName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text(run.commandLabel)
                        .font(.system(size: 10, design: .monospaced))
                    Text("·")
                        .font(.system(size: 10))
                    Text((run.packageDir.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            StatusBadge(status: run.status)
            Spacer(minLength: 12)
            if run.status.isActive {
                Button {
                    runs.stop(run.id)
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .disabled(run.status == .stopping)
                .help(run.status == .stopping
                      ? "Arrêt en cours…"
                      : "Arrête le script proprement (Ctrl-C, puis kill si besoin)")
                .accessibilityLabel("Arrêter le script « \(run.scriptName) »")
            }
            Button(role: .destructive) {
                runs.close(run.id)
            } label: {
                Label("Fermer", systemImage: "xmark.circle.fill")
            }
            .help(run.status.isActive
                  ? "Ferme le run et arrête le script"
                  : "Ferme le run et libère le terminal")
            .accessibilityLabel("Fermer le run « \(run.scriptName) »")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var centerEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Aucune sélection")
                .font(.title3.weight(.semibold))
            Text("Sélectionnez un projet dans la barre latérale pour voir ses scripts, ou une exécution pour suivre son terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(.background)
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

    /// Chemins des packages ayant au moins un run encore actif (pastille verte).
    private var activeRunDirs: Set<String> {
        Set(runs.runs.lazy.filter { $0.status.isActive }.map { $0.packageDir.path })
    }

    /// Le package sélectionné, résolu dans les projets (racine OU sous-package),
    /// avec la racine du projet contenant (lockfile / nom affiché). `nil` si la
    /// sélection ne référence plus rien (package disparu au re-scan).
    private var selectedPackageContext: (package: ScriptPackage, projectRoot: URL, projectName: String)? {
        guard case .package(let id)? = runs.selection else { return nil }
        for project in packages.projects {
            if project.root.id == id {
                return (project.root, project.root.dir, project.root.name)
            }
            if let sub = project.subpackages.first(where: { $0.id == id }) {
                return (sub, project.root.dir, project.root.name)
            }
        }
        return nil
    }

    private var displayedProjects: [PackageProject] {
        guard !searchText.isEmpty else { return packages.projects }
        return packages.projects.filter { project in
            matchesFilter(project.root) || project.subpackages.contains(where: matchesFilter)
        }
    }

    private func matchesFilter(_ package: ScriptPackage) -> Bool {
        package.name.localizedCaseInsensitiveContains(searchText)
            || package.path.localizedCaseInsensitiveContains(searchText)
    }

    /// Workspaces affichés sous un projet : tous hors filtre (ou si la racine
    /// matche elle-même) ; seulement ceux qui matchent sinon.
    private func displayedSubpackages(of project: PackageProject) -> [ScriptPackage] {
        guard !searchText.isEmpty, !matchesFilter(project.root) else { return project.subpackages }
        return project.subpackages.filter(matchesFilter)
    }

    /// Un projet retenu par le filtre via ses seuls workspaces est déplié d'office
    /// (sinon le résultat de la recherche resterait invisible).
    private func isExpanded(_ project: PackageProject) -> Bool {
        if !searchText.isEmpty && !matchesFilter(project.root) { return true }
        return expanded.contains(project.id)
    }

    private func toggleExpanded(_ project: PackageProject) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(project.id) {
                expanded.remove(project.id)
            } else {
                expanded.insert(project.id)
            }
        }
    }

    private func revealSelectedSubpackage() {
        guard case .package(let id)? = runs.selection else { return }
        for project in packages.projects
        where project.subpackages.contains(where: { $0.id == id }) {
            expanded.insert(project.id)
            return
        }
    }
}

// MARK: - Statut d'un run (rendu partagé sidebar / header)

/// Mêmes règles partout : running = vert (pulse), stopping = orange,
/// exit 0 = coche verte, exit ≠ 0 = rouge (code affiché), tué = gris « arrêté ».
private extension ScriptRun.Status {
    var tint: Color {
        switch self {
        case .running: return .green
        case .stopping: return .orange
        case .exited(let code):
            guard let code else { return .gray }
            return code == 0 ? .green : .red
        case .killed: return .gray
        }
    }

    var label: String {
        switch self {
        case .running: return "En cours"
        case .stopping: return "Arrêt…"
        case .exited(let code):
            guard let code else { return "Terminé" }
            return code == 0 ? "Terminé" : "Échec (code \(code))"
        case .killed: return "Arrêté"
        }
    }
}

/// Pastille compacte (lignes de la sidebar). Le vert « running » pulse
/// discrètement ; un exit ≠ 0 affiche le code dans une capsule rouge.
private struct StatusPill: View {
    let status: ScriptRun.Status
    @State private var pulsing = false

    var body: some View {
        pill
            .frame(width: 18)
            .accessibilityLabel("Statut : \(status.label)")
    }

    @ViewBuilder
    private var pill: some View {
        switch status {
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
        case .stopping:
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
        case .exited(let code):
            if let code, code != 0 {
                Text("\(code)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(code == nil ? Color.gray : Color.green)
            }
        case .killed:
            Image(systemName: "stop.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.gray)
        }
    }
}

/// Badge texte (header du run au centre) : libellé + teinte du statut.
private struct StatusBadge: View {
    let status: ScriptRun.Status

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(status.tint.opacity(0.15)))
            .accessibilityLabel("Statut : \(status.label)")
    }
}

// MARK: - Ligne de run

private struct RunRow: View {
    let run: ScriptRun
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    /// « projet · package » — réduit au seul nom quand le run part de la racine
    /// (sinon « proj · proj », redondant).
    private var subtitle: String {
        run.projectName == run.packageName
            ? run.projectName
            : "\(run.projectName) · \(run.packageName)"
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusPill(status: run.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.scriptName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(run.status.isActive
                      ? "Fermer le run (arrête le script)"
                      : "Fermer le run (libère le terminal)")
                .accessibilityLabel("Fermer le run « \(run.scriptName) »")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help("Afficher « \(run.scriptName) » (\(run.status.label)) au centre")
    }
}

// MARK: - Ligne de projet

private struct ProjectRow: View {
    let project: PackageProject
    let isSelected: Bool
    let isExpanded: Bool
    let hasActiveRun: Bool
    let onSelect: () -> Void
    let onToggleExpand: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Chevron disclosure — seulement pour les monorepos (workspaces).
            // Zone vide de même largeur sinon, pour garder les icônes alignées.
            if project.subpackages.isEmpty {
                Color.clear.frame(width: 14, height: 14)
            } else {
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded
                      ? "Replier les workspaces"
                      : "Déplier les workspaces (\(project.subpackages.count))")
                .accessibilityLabel(isExpanded
                                    ? "Replier les workspaces de « \(project.name) »"
                                    : "Déplier les workspaces de « \(project.name) »")
            }

            ZStack(alignment: .topLeading) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                if hasActiveRun {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: -3, y: -3)
                        .help("Au moins un script tourne dans ce projet")
                        .accessibilityLabel("Script en cours")
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(project.root.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(project.root.path)
    }
}

// MARK: - Ligne de sous-package (workspace)

private struct SubpackageRow: View {
    let package: ScriptPackage
    /// Racine du projet contenant (calcul du chemin relatif affiché).
    let projectRoot: URL
    let isSelected: Bool
    let hasActiveRun: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    /// Chemin relatif à la racine du projet (« packages/app ») : le nom seul est
    /// souvent ambigu dans un monorepo.
    private var relativePath: String {
        let rootPrefix = projectRoot.path + "/"
        guard package.path.hasPrefix(rootPrefix) else { return package.displayPath }
        return String(package.path.dropFirst(rootPrefix.count))
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                // Même icône que le projet, plus petite et secondaire.
                Image(systemName: "cube.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                if hasActiveRun {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: -3, y: -3)
                        .help("Au moins un script tourne dans ce package")
                        .accessibilityLabel("Script en cours")
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(package.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relativePath)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 28)   // indentation sous le projet parent
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(package.path)
    }
}
