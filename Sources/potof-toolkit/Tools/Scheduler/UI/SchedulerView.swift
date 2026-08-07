import SwiftUI

/// Outil « Superset Scheduler » — **lot L4**.
///
/// Disposition en deux volets (`HSplitView`, **jamais `NavigationSplitView`** : son toggle
/// automatique ne s'ancre pas dans une fenêtre hébergée manuellement et « saute ») :
/// - **Sidebar** : les planifications, avec leur cadence en clair, le statut du dernier
///   run et l'interrupteur d'activation. **Pas d'en-tête de section** : la sidebar ne
///   contient que cette liste et n'en contiendra pas d'autre — un titre pour une section
///   unique ne fait que manger de la hauteur.
/// - **Centre** : le détail de la sélection, ou le formulaire **présenté en place** —
///   le dépôt n'a aucune `.sheet`, refus documenté dans `RebasePanelView`.
///
/// Le détail suit la forme de `RepoDetailView` : **top bar d'actions** (`.background(.bar)`)
/// puis un corps à **onglets** (`Picker` segmenté). Les onglets existent parce que le
/// prompt et l'historique se disputaient la hauteur : un prompt d'automation fait des
/// dizaines de lignes, et l'encadré fixe qui le montrait en laissait voir cinq.
/// **`Historique` est l'onglet par défaut** — c'est ce qu'on vient regarder.
///
/// L'état vit dans `ScheduleStore.shared` (fichiers surveillés) et
/// `SchedulerService.shared` (audit) : il **survit au changement d'outil**, la vue n'étant
/// qu'une projection jetable (`RootView` pose `.id(tool.id)` et détruit tout au switch).
struct SchedulerView: View {

    static let toolID: Tool.ID = "scheduler"

    @ObservedObject private var store = ScheduleStore.shared
    @ObservedObject private var service = SchedulerService.shared

    /// Édition en cours. `nil` = on affiche le détail.
    @State private var editing: Editing?
    @State private var pendingDeletion: Schedule?
    /// Dernier retour d'une action de la top bar, affiché juste sous elle.
    @State private var diagnostic: String?
    /// ⭐ `.history` par défaut : l'historique est ce qu'on vient vérifier (« est-ce que
    /// ça a tourné cette nuit ? »). Le prompt, lui, se consulte à l'occasion.
    @State private var tab: DetailTab = .history
    /// Dernier rapport de simulation, pour l'onglet « Plan ». Jamais persisté : c'est une
    /// photo de l'état du poste à l'instant du clic.
    ///
    /// ⭐ Il porte **l'identifiant de sa planification**, et l'onglet ne l'affiche que si
    /// elle est bien celle à l'écran. Un simple `String?` aurait montré le plan de « Sentry
    /// Report — Portal » sous « Sentry Report — Shopify apps » au premier changement de
    /// sélection ; le lier à son sujet couvre d'un coup tous les chemins (sélection,
    /// rechargement, suppression), sans avoir à les recenser.
    @State private var plan: Plan?
    @State private var simulating = false

    private struct Plan { let scheduleID: UUID; let report: String }

    private enum Editing: Equatable {
        case creating
        case existing(UUID)
    }

    private enum DetailTab: Hashable { case history, prompt, plan }

    var body: some View {
        VStack(spacing: 0) {
            banners
            HSplitView {
                sidebar
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                center
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 500)
        .onAppear { store.reload() }
    }

    // MARK: - Bandeaux

    @ViewBuilder
    private var banners: some View {
        // ⚠️ À NE PAS retirer : sans ça, personne ne comprend pourquoi l'interrupteur
        // « Activé » est grisé en développement.
        if !SchedulePaths.canInstallLaunchAgents {
            banner(
                icon: "hammer.fill",
                tint: .orange,
                text: "Version de développement : les planifications ne s'installent pas dans "
                    + "launchd. Le formulaire, l'historique et « Lancer maintenant » "
                    + "fonctionnent ; l'activation, non."
            )
        }
        let audit = AuditSummary(service.auditIssues)
        if !audit.isEmpty {
            auditBanner(audit)
        }
        if let error = store.lastError {
            banner(icon: "exclamationmark.triangle.fill", tint: .red, text: error)
        }
    }

    /// Ventilation des anomalies d'`audit()` en ce que le bandeau sait dire et proposer.
    ///
    /// ⭐ **`switch` exhaustif, surtout pas une série de `filter`** : ajouter un cas à
    /// `AuditIssue` doit casser la compilation ici. Un cas non traité ne disparaissait pas
    /// de l'écran — il produisait un bandeau orange **vide**, sans texte ni bouton, parce
    /// que `banners` l'affiche dès que `auditIssues` est non vide. C'est exactement ce qui
    /// arrivait à `.notLoaded`, la classe la plus actionnable des trois.
    private struct AuditSummary {
        var mismatches: [UUID] = []
        var notLoaded: [UUID] = []
        var orphans: [String] = []

        init(_ issues: [AuditIssue]) {
            for issue in issues {
                switch issue {
                case .pathMismatch(let id, _): mismatches.append(id)
                case .notLoaded(let id):       notLoaded.append(id)
                case .orphanPlist(let name):   orphans.append(name)
                }
            }
        }

        var isEmpty: Bool { mismatches.isEmpty && notLoaded.isEmpty && orphans.isEmpty }

        /// `repairAll` réinstalle les planifications activées : c'est le remède des DEUX
        /// premières classes, pas seulement du déplacement de l'application.
        var isRepairable: Bool { !mismatches.isEmpty || !notLoaded.isEmpty }
    }

    private func auditBanner(_ audit: AuditSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if !audit.mismatches.isEmpty {
                    Text("\(audit.mismatches.count) planification(s) pointent vers un autre emplacement "
                         + "de l'application — launchd ne les déclenchera pas.")
                        .font(.system(size: 12))
                }
                if !audit.notLoaded.isEmpty {
                    Text("\(audit.notLoaded.count) planification(s) activée(s) dont le job launchd "
                         + "n'est pas chargé — elles ne se déclencheront pas.")
                        .font(.system(size: 12))
                }
                if !audit.orphans.isEmpty {
                    Text("\(audit.orphans.count) job(s) launchd sans planification correspondante.")
                        .font(.system(size: 12))
                }
            }
            Spacer()
            if audit.isRepairable {
                Button("Réparer") { repairAll() }
                    .help("Réinstalle les jobs launchd des planifications activées avec le "
                          + "chemin actuel de l'application, et retire ceux des désactivées.")
            }
            if !audit.orphans.isEmpty {
                Button("Purger") { purgeOrphans(audit.orphans) }
                    .help("Supprime les fichiers launchd qui ne correspondent à aucune "
                          + "planification. Seuls les fichiers dont le nom ET le programme "
                          + "sont les nôtres sont touchés.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.schedules.isEmpty {
                emptyMessage(icon: "calendar.badge.plus",
                             text: "Aucune planification.\nCréez-en une pour lancer un agent "
                                 + "Superset à heure fixe.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.schedules) { schedule in
                            ScheduleRow(
                                schedule: schedule,
                                lastRun: store.lastRun(of: schedule.id),
                                isSelected: store.selection == schedule.id,
                                canInstall: SchedulePaths.canInstallLaunchAgents,
                                onSelect: {
                                    store.selection = schedule.id
                                    editing = nil
                                    diagnostic = nil
                                },
                                onToggle: { store.setEnabled($0, id: schedule.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    // L'en-tête de section a disparu : sans cette marge, la première ligne
                    // colle à la barre de titre de la fenêtre.
                    .padding(.vertical, 8)
                }
            }
            Divider()
            sidebarFooter
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }

    private var sidebarFooter: some View {
        HStack {
            Button {
                editing = .creating
                diagnostic = nil
            } label: {
                Label("Nouvelle planification", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Créer une planification.")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Centre

    @ViewBuilder
    private var center: some View {
        switch editing {
        case .creating:
            ScheduleFormView(
                draft: nil,
                onSave: { save($0) },
                onCancel: { editing = nil })
        case .existing(let id):
            if let schedule = store.schedules.first(where: { $0.id == id }) {
                ScheduleFormView(
                    draft: schedule,
                    onSave: { save($0) },
                    onCancel: { editing = nil })
            } else {
                emptyMessage(icon: "questionmark.folder", text: "Planification introuvable.")
            }
        case nil:
            if let id = store.selection,
               let schedule = store.schedules.first(where: { $0.id == id }) {
                detail(schedule)
            } else {
                emptyMessage(icon: "calendar.badge.clock",
                             text: "Sélectionnez une planification.")
            }
        }
    }

    private func detail(_ schedule: Schedule) -> some View {
        VStack(spacing: 0) {
            actionBar(schedule)
            Divider()
            if let diagnostic {
                diagnosticRow(diagnostic)
                Divider()
            }
            summary(schedule)
            Divider()
            tabPicker(schedule)
            Divider()
            // Le contenu d'onglet prend TOUTE la hauteur restante et défile chez lui :
            // c'est ce qui rend un prompt de cinquante lignes lisible.
            tabContent(schedule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Supprimer « \(pendingDeletion?.name ?? "") » ?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let victim = pendingDeletion {
                    store.remove(id: victim.id)
                    if store.selection == victim.id { store.selection = nil }
                }
                pendingDeletion = nil
            }
            Button("Annuler", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Le job launchd est retiré. L'historique des runs est conservé.")
        }
    }

    private func detailHeader(_ schedule: Schedule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(schedule.name).font(.system(size: 17, weight: .semibold))
            if !schedule.enabled {
                Text("désactivée")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func detailFacts(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Cadence", LaunchAgentPlist.humanDescription(schedule.recurrence))
            fact("Prochaine exécution", nextFireText(schedule))
            fact("Agent", agentText(schedule))
            fact("Cible", schedule.target.summary)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
        }
    }

    /// ⚠️ Une planification désactivée n'a **aucune** prochaine exécution : afficher une
    /// date ici laisserait croire qu'elle va partir.
    private func nextFireText(_ schedule: Schedule) -> String {
        guard schedule.enabled else { return "— (planification désactivée)" }
        guard SchedulePaths.canInstallLaunchAgents else {
            return "— (non installée : version de développement)"
        }
        guard let date = LaunchAgentPlist.nextFireDate(
            schedule.recurrence, after: Date(), calendar: .current)
        else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM 'à' HH:mm"
        return formatter.string(from: date)
    }

    private func agentText(_ schedule: Schedule) -> String {
        let effort = schedule.action.effort.map { " · effort \($0)" } ?? ""
        return schedule.action.agentRef + effort
    }

    // MARK: - Top bar d'actions

    /// ⭐ **Une seule action garde son libellé** — celle qu'on vient faire. Les autres sont
    /// des boutons-icônes, exactement comme la top bar de `RepoDetailView` : à cinq
    /// libellés la barre dépassait la largeur minimale du volet central (480 pt) et se
    /// faisait rogner. Tout bouton-icône porte `.help()` **et** `.accessibilityLabel()`.
    private func actionBar(_ schedule: Schedule) -> some View {
        HStack(spacing: 12) {
            Button {
                diagnostic = nil
                store.runNow(id: schedule.id)
            } label: {
                Label("Lancer maintenant", systemImage: "play.fill")
            }
            .help("Exécute la planification immédiatement, avec les mêmes garde-fous qu'un "
                  + "déclenchement launchd.")
            .accessibilityLabel("Lancer maintenant")

            barButton("pencil", label: "Modifier la planification",
                      help: "Modifier cette planification.") {
                editing = .existing(schedule.id)
            }
            barButton("arrow.up.forward.app", label: "Ouvrir le workspace dans Superset",
                      help: "Ouvre le workspace dans Superset — celui du dernier run s'il y "
                          + "en a eu un, sinon celui que désigne la cible.") {
                openWorkspace(schedule)
            }
            barButton("doc.text.magnifyingglass", label: "Simuler le prochain run",
                      help: "Simulation (dry-run) : déroule exactement ce que ferait le "
                          + "déclenchement de 10:00 — argv, prompt, garde-fous qui "
                          + "bloqueraient — et l'affiche dans l'onglet « Plan ». "
                          + "AUCUN effet de bord : ni workspace, ni agent, ni ligne "
                          + "d'historique.",
                      disabled: simulating) {
                simulate(schedule)
            }
            if simulating { ProgressView().controlSize(.small) }

            Spacer(minLength: 12)

            barButton("trash", label: "Supprimer la planification",
                      help: "Supprime la planification et son job launchd.",
                      tint: .red) {
                pendingDeletion = schedule
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Gabarit repris de `RepoDetailView.barButton` — même forme, même discrétion.
    private func barButton(_ systemName: String, label: String, help: String,
                           disabled: Bool = false, tint: Color = .secondary,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).font(.system(size: 13)) }
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(label)
    }

    /// Retour des actions de la barre. Refermable : c'est un message ponctuel, pas un
    /// bandeau d'état — le laisser traîner ferait croire à une condition persistante.
    private func diagnosticRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button { diagnostic = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Masquer ce message.")
            .accessibilityLabel("Masquer le message de diagnostic")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Résumé et onglets

    private func summary(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailHeader(schedule)
            detailFacts(schedule)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabPicker(_ schedule: Schedule) -> some View {
        let runCount = store.runs(of: schedule.id).count
        return Picker("", selection: $tab) {
            Text(runCount > 0 ? "Historique (\(runCount))" : "Historique")
                .tag(DetailTab.history)
            Text("Prompt").tag(DetailTab.prompt)
            Text("Plan").tag(DetailTab.plan)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func tabContent(_ schedule: Schedule) -> some View {
        switch tab {
        case .history:
            ScrollView {
                ScheduleRunHistoryView(scheduleID: schedule.id)
                    .padding(20)
            }
        case .prompt:
            // ⭐ La raison d'être des onglets : le prompt dispose de toute la hauteur
            // restante. L'encadré de 180 pt qu'il occupait avant en laissait voir cinq
            // lignes sur cinquante, et il n'y avait aucun moyen de lire le reste sans
            // ouvrir le formulaire d'édition.
            ScrollView {
                Text(schedule.action.prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        case .plan:
            planPane(schedule)
        }
    }

    /// Rapport de la dernière simulation. Vide tant qu'on n'a pas simulé — avec de quoi
    /// le faire depuis là, sinon l'onglet est une impasse.
    @ViewBuilder
    private func planPane(_ schedule: Schedule) -> some View {
        if let plan, plan.scheduleID == schedule.id {
            ScrollView([.horizontal, .vertical]) {
                Text(plan.report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Aucune simulation.\nElle déroule ce que ferait le prochain "
                     + "déclenchement — sans rien exécuter.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Simuler maintenant") { simulate(schedule) }
                    .disabled(simulating)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func save(_ schedule: Schedule) {
        store.upsert(schedule)
        store.selection = schedule.id
        editing = nil
        // La planification vient de changer : le plan simulé décrit l'ancienne.
        plan = nil
    }

    /// Ouvre le workspace dans Superset. Deux sources d'identifiant, dans cet ordre :
    /// 1. **le dernier run** — c'est presque toujours ce qu'on veut voir après coup, et
    ///    c'est la seule source possible pour une cible « nouveau workspace à chaque run » ;
    /// 2. à défaut, la résolution par coordonnées `(projet, nom)` de la cible permanente.
    ///
    /// La planification ne stocke **pas** d'identifiant de workspace (il change si on le
    /// supprime puis le recrée), d'où cette résolution à la demande.
    private func openWorkspace(_ schedule: Schedule) {
        let lastKnown = store.lastRun(of: schedule.id)?.workspaceID
        diagnostic = "Ouverture du workspace…"
        DispatchQueue.global(qos: .userInitiated).async {
            var workspaceID = lastKnown
            var problem: String?

            if workspaceID == nil {
                if case .permanentWorkspace(let projectID, _, let name, _, _, _) = schedule.target {
                    let matches = (SupersetCLI.workspaces() ?? [])
                        .filter { $0.projectId == projectID && $0.name == name }
                    if matches.count > 1 {
                        // Même règle que le runner : plusieurs homonymes ⇒ ambigu, on
                        // n'en choisit pas un au hasard.
                        problem = "\(matches.count) workspaces s'appellent « \(name) » dans "
                                + "ce projet : impossible de choisir."
                    } else if let found = matches.first {
                        workspaceID = found.id
                    } else {
                        problem = "Le workspace « \(name) » n'existe pas encore — "
                                + "il sera créé au premier run."
                    }
                } else {
                    problem = "Aucun run enregistré : le workspace n'a pas encore été créé."
                }
            }

            let message: String
            if let problem {
                message = problem
            } else if let workspaceID {
                let result = SupersetCLI.openWorkspace(id: workspaceID)
                message = result.ok
                    ? "Workspace ouvert dans Superset."
                    : "Ouverture impossible : \(result.message)"
            } else {
                message = "Workspace introuvable."
            }
            DispatchQueue.main.async { diagnostic = message }
        }
    }

    /// Simulation du prochain déclenchement — **le seul « test » de cette UI**.
    ///
    /// ⭐ `trigger: launchd` et non `"cli"` : on simule le tir de 10:00, pas un lancement
    /// à la main. La distinction n'est pas décorative — le runner traite une planification
    /// désactivée différemment selon le déclencheur, et c'est justement le genre de
    /// surprise qu'on veut voir dans le plan. Aucune bannière n'en sort pour autant :
    /// `notify` n'est appelée que hors dry-run.
    ///
    /// Effets de bord : **aucun**. Le `Reporter` n'a pas de `RunLog`, aucun verrou n'est
    /// posé, aucun `create` n'est exécuté. Les seuls appels sortants sont des lectures
    /// (`status`, `workspaces list`), d'où la file de fond : c'est bloquant.
    private func simulate(_ schedule: Schedule) {
        guard !simulating else { return }
        simulating = true
        diagnostic = nil
        tab = .plan
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = SchedulerService.shared.isLoaded(schedule)
            let outcome = ScheduleRunner.executeReporting(
                schedule, trigger: LaunchAgentPlist.launchdTriggerValue, dryRun: true)
            // `isLoaded` répond à la seule question que l'ancien kickstart tranchait
            // vraiment, et il y répond sans rien déclencher.
            let header = SchedulePaths.canInstallLaunchAgents
                ? "job launchd chargé : \(loaded ? "oui" : "NON — la planification ne partira pas")"
                : "job launchd : non installé (version de développement)"
            DispatchQueue.main.async {
                plan = Plan(scheduleID: schedule.id, report: header + "\n\n" + outcome.report)
                simulating = false
            }
        }
    }

    private func repairAll() {
        let schedules = store.schedules
        DispatchQueue.global(qos: .userInitiated).async {
            let results = SchedulerService.shared.repairAll(schedules)
            let failed = results.filter { !$0.ok }
            DispatchQueue.main.async {
                SchedulerService.shared.auditOnLaunch()
                diagnostic = failed.isEmpty
                    ? "Réparation : \(results.count)/\(results.count) OK."
                    : "Réparation : \(failed.count) échec(s) — "
                      + failed.map(\.message).joined(separator: " ; ")
            }
        }
    }

    private func purgeOrphans(_ names: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = names.map { SchedulerService.shared.removeOrphan(plistNamed: $0) }
            let failed = results.filter { !$0.ok }
            DispatchQueue.main.async {
                SchedulerService.shared.auditOnLaunch()
                diagnostic = failed.isEmpty
                    ? "Purge : \(results.count) orphelin(s) supprimé(s)."
                    : "Purge : \(failed.count) refus — " + failed.map(\.message).joined(separator: " ; ")
            }
        }
    }

    // MARK: - Fragments partagés

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
}

// MARK: - Ligne de la sidebar

private struct ScheduleRow: View {
    let schedule: Schedule
    let lastRun: RunRecord?
    let isSelected: Bool
    let canInstall: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(LaunchAgentPlist.humanDescription(schedule.recurrence))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let lastRun {
                    RunStatusPill(status: lastRun.status, date: lastRun.startedAt)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { schedule.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!canInstall)
                .help(canInstall
                      ? "Activer ou désactiver le déclenchement automatique."
                      : "Les planifications ne s'installent que depuis l'app bundlée. "
                        + "En dev, utilisez « Lancer maintenant ».")
                .accessibilityLabel("Activer la planification « \(schedule.name) »")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Pastille de statut du dernier run.
///
/// ⚠️ `launched` ne s'écrit **jamais** « réussi » : le runner sait seulement qu'il a su
/// lancer l'agent, pas ce que celui-ci a produit. Et `skipped` (orange) se distingue de
/// `failed` (rouge) — un garde-fou qui joue n'est pas une panne, et les confondre revient
/// à crier au loup tous les jours jusqu'à ne plus regarder.
struct RunStatusPill: View {
    let status: RunStatus
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("\(label) · \(Self.relative(date))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Dernier run : \(label), \(Self.relative(date))")
    }

    private var label: String {
        switch status {
        case .launched:    return "agent lancé"
        case .failed:      return "échec"
        case .skipped:     return "sauté"
        case .running:     return "en cours"
        case .interrupted: return "interrompu"
        }
    }

    private var tint: Color {
        switch status {
        case .launched:    return .green
        case .failed:      return .red
        case .skipped:     return .orange
        case .running:     return .blue
        case .interrupted: return .gray
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
