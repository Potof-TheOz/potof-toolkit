import SwiftUI

/// Formulaire de création / édition — **lot L4bis**.
///
/// **Présenté en place au centre, PAS en `.sheet`** : le dépôt n'a aucune `.sheet`, refus
/// documenté dans `RebasePanelView`.
///
/// ## La règle qui gouverne tout ce fichier
/// **Aucune indisponibilité de Superset ne doit empêcher d'enregistrer.** Le host service
/// peut être éteint alors que la planification est parfaitement valide — et elle sera
/// exécutée dans six heures, quand il aura redémarré. Toute information venue de la CLI
/// est donc un **confort** (liste d'agents, liste de projets), jamais une condition :
/// `validate()` ne regarde que des données locales, et le sélecteur d'agent retombe en
/// saisie libre quand la liste est illisible.
///
/// ## Sections repliables, et pourquoi
/// Cinq volets — Identité, Agent, Cadence, Cible, Prompt — chacun repliable et **montrant
/// son résumé une fois fermé**. En déroulé complet, le formulaire faisait cohabiter trois
/// conventions d'étiquetage (titre au-dessus ici, gouttière à gauche dans `TargetPicker`,
/// phrases inline dans `RecurrencePicker`) : l'œil ne retrouvait jamais le même point de
/// départ. Replié, chaque volet se lit d'une ligne et l'inspection d'ensemble redevient
/// possible sans dérouler deux écrans.
///
/// ⚠️ **Deux règles qui font que le pliage ne cache rien :**
/// 1. En **création**, tout est déplié — replier des champs obligatoires encore vides
///    reviendrait à les dissimuler.
/// 2. À l'enregistrement, les volets **fautifs se déplient tout seuls** (cf.
///    `Schedule.ValidationReport`). Sans ça, « Le prompt est obligatoire » s'afficherait
///    au-dessus d'une section fermée.
struct ScheduleFormView: View {

    let draft: Schedule?
    let onSave: (Schedule) -> Void
    let onCancel: () -> Void

    init(draft: Schedule?,
         onSave: @escaping (Schedule) -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel

        let seed = draft ?? Self.blank()
        _name = State(initialValue: seed.name)
        _prompt = State(initialValue: seed.action.prompt)
        _agentRef = State(initialValue: seed.action.agentRef)
        _effort = State(initialValue: seed.action.effort ?? "")
        _recurrence = State(initialValue: seed.recurrence)
        _target = State(initialValue: seed.target)
        // Création : tout ouvert (cf. règle 1 de l'en-tête). Modification : on n'ouvre que
        // l'identité et le prompt, le reste se relit dans les résumés.
        _expanded = State(initialValue: draft == nil
            ? Set(FormSection.allCases)
            : [.identity, .prompt])
    }

    @ObservedObject private var store = ScheduleStore.shared

    @State private var name: String
    @State private var prompt: String
    @State private var agentRef: String
    @State private var effort: String
    @State private var recurrence: Recurrence
    @State private var target: Target

    @State private var agents: [SupersetAgentConfig] = []
    @State private var agentsUnavailable = false
    @State private var showErrors = false
    @State private var expanded: Set<FormSection>

    /// ⭐ Tiré **une seule fois**. `candidate` est une propriété calculée : un `UUID()` à
    /// la volée en aurait produit un différent à chaque lecture, et `report` en fait deux.
    @State private var newID = UUID()

    /// Les cinq volets, dans l'ordre d'affichage.
    private enum FormSection: String, CaseIterable, Hashable {
        case identity, agent, recurrence, target, prompt

        var title: String {
            switch self {
            case .identity:   return "Identité"
            case .agent:      return "Agent"
            case .recurrence: return "Cadence"
            case .target:     return "Cible"
            case .prompt:     return "Prompt"
            }
        }
    }

    /// `nil` = « laisser l'agent décider », ce que la CLI documente comme le défaut.
    private static let efforts = ["", "low", "medium", "high", "xhigh"]

    private static func blank() -> Schedule {
        Schedule(
            name: "",
            action: .supersetAgent(agentRef: Action.defaultAgentRef, effort: nil, prompt: ""),
            recurrence: .daily(hour: 9, minute: 0),
            target: .permanentWorkspace(projectID: "", projectName: "", workspaceName: "",
                                        branch: "", baseBranch: "main", refreshWorktree: true))
    }

    /// Le préfixe de nom laissé vide reprend le **nom de la planification**, et il est
    /// matérialisé ici plutôt que déduit au lancement : un préfixe implicite qui changerait
    /// le jour où l'on renomme la planification ferait perdre au plafond le compte des
    /// workspaces déjà créés.
    private var normalizedTarget: Target {
        guard case .freshWorkspace(let projectID, let projectName, let namePrefix,
                                   let branchPrefix, let baseBranch) = target,
              namePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return target }
        return .freshWorkspace(
            projectID: projectID, projectName: projectName,
            namePrefix: name.trimmingCharacters(in: .whitespacesAndNewlines),
            branchPrefix: branchPrefix, baseBranch: baseBranch)
    }

    private var candidate: Schedule {
        Schedule(
            id: draft?.id ?? newID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: draft?.enabled ?? true,
            action: .supersetAgent(
                agentRef: agentRef,
                effort: effort.isEmpty ? nil : effort,
                prompt: prompt),
            recurrence: recurrence,
            target: normalizedTarget,
            createdAt: draft?.createdAt ?? Date(),
            updatedAt: Date())
    }

    private var report: Schedule.ValidationReport {
        let candidate = self.candidate
        let otherNames = Set(store.schedules
            .filter { $0.id != candidate.id }
            .map { $0.name })
        return candidate.validationReport(existingNames: otherNames)
    }

    /// Volets en erreur — c'est ce qui permet de les déplier à l'enregistrement.
    private func invalidSections(_ report: Schedule.ValidationReport) -> Set<FormSection> {
        var result: Set<FormSection> = []
        if !report.identity.isEmpty   { result.insert(.identity) }
        if !report.agent.isEmpty      { result.insert(.agent) }
        if !report.prompt.isEmpty     { result.insert(.prompt) }
        if !report.recurrence.isEmpty { result.insert(.recurrence) }
        if !report.target.isEmpty     { result.insert(.target) }
        return result
    }

    // MARK: - Résumés des volets repliés

    private var identitySummary: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "sans nom" : trimmed
    }

    private var agentSummary: String {
        let display = agents.first { $0.id == agentRef }?.displayName
            ?? (agentRef.isEmpty ? "aucun agent" : agentRef)
        return effort.isEmpty ? "\(display) · effort par défaut" : "\(display) · effort \(effort)"
    }

    private var promptSummary: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "vide" }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1,
                                      omittingEmptySubsequences: false).first ?? ""
        return "\(trimmed.count) caractères — \(firstLine)"
    }

    private func summary(_ section: FormSection) -> String {
        switch section {
        case .identity:   return identitySummary
        case .agent:      return agentSummary
        case .recurrence: return LaunchAgentPlist.humanDescription(recurrence)
        case .target:     return normalizedTarget.summary
        case .prompt:     return promptSummary
        }
    }

    var body: some View {
        let report = self.report
        let invalid = showErrors ? invalidSections(report) : []
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(draft == nil ? "Nouvelle planification" : "Modifier la planification")
                        .font(.system(size: 17, weight: .semibold))

                    disclosure(.identity, invalid: invalid) {
                        TextField("Relevé Sentry — Shopify-Apps", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                            .accessibilityLabel("Nom de la planification")
                    }
                    disclosure(.agent, invalid: invalid) { agentControls }
                    disclosure(.recurrence, invalid: invalid) {
                        RecurrencePicker(recurrence: $recurrence)
                    }
                    disclosure(.target, invalid: invalid) { TargetPicker(target: $target) }
                    disclosure(.prompt, invalid: invalid, separator: false) { promptEditor }

                    if showErrors && !report.all.isEmpty { errorBox(report.all) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .onAppear(perform: loadAgents)
    }

    // MARK: - Volet repliable

    /// En-tête cliquable + contenu. **Fermé, il affiche le résumé de ce qu'il contient** :
    /// c'est ce qui autorise à replier sans perdre la relecture d'ensemble. Un volet en
    /// erreur porte sa pastille orange, visible même replié.
    @ViewBuilder
    private func disclosure<Content: View>(
        _ section: FormSection,
        invalid: Set<FormSection>,
        separator: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = expanded.contains(section)
        let isInvalid = invalid.contains(section)
        let text = summary(section)

        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(section) } else { expanded.insert(section) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .frame(width: 74, alignment: .leading)
                    if isInvalid {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    if !isOpen {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(isInvalid ? .orange : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Replier « \(section.title) »."
                         : "Déplier « \(section.title) » — \(text)")
            .accessibilityLabel(section.title)
            .accessibilityValue(isOpen ? "déplié" : "replié : \(text)")

            if isOpen {
                content()
                    // Aligné sur le titre, pas sur le chevron : le contenu se rattache
                    // visuellement à son volet.
                    .padding(.leading, 18)
            }
            // Le dernier volet n'en pose pas : la barre fixe a déjà le sien, et les deux
            // traits se seraient collés.
            if separator { Divider() }
        }
    }

    // MARK: - Agent

    @ViewBuilder
    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if agentsUnavailable {
                // Repli en saisie libre : refuser d'enregistrer parce que la liste est
                // illisible serait pire que de laisser saisir une référence à la main.
                HStack(spacing: 8) {
                    TextField("claude, ou l'identifiant d'une configuration d'agent",
                              text: $agentRef)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .accessibilityLabel("Référence de l'agent")
                    Button("Réessayer") {
                        agentsUnavailable = false
                        loadAgents()
                    }
                    .help("Relire la liste des agents configurés sur cette machine.")
                }
                Text("Liste des agents indisponible (Superset injoignable) — saisie libre.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Picker("", selection: $agentRef) {
                    if !agents.contains(where: { $0.id == agentRef }) {
                        Text(agentRef.isEmpty ? "— choisir —" : agentRef).tag(agentRef)
                    }
                    ForEach(agents) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 420)
            }

            HStack(spacing: 8) {
                Text("Effort")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $effort) {
                    ForEach(Self.efforts, id: \.self) { value in
                        Text(value.isEmpty ? "défaut de l'agent" : value).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .help("Laisser « défaut de l'agent » sauf besoin précis : la valeur dépend "
                      + "de l'agent, et une valeur inconnue serait refusée au lancement.")
                Spacer()
            }

            // ⚠️ Point de sécurité, pas de confort. On ne devine plus d'après le nom :
            // on regarde les `args` de la configuration, exactement comme le script de
            // référence, qui REFUSE de lancer si l'agent ne charge pas son `--settings`.
            if let selected = agents.first(where: { $0.id == agentRef }),
               !selected.loadsCustomSettings {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange).font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text("« \(selected.displayName) » ne charge aucun profil de permissions "
                         + "(pas de `--settings` dans ses arguments) : la session tournera "
                         + "avec les permissions par défaut. Pour un agent qui s'exécute "
                         + "seul, préférez une configuration au périmètre restreint.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// `agents list` **synthétise** une entrée « Superset » (`id == "superset"`,
    /// `command == "(superset runtime)"`) qui n'existe pas dans `host_agent_configs` —
    /// impossible à supprimer côté Superset, et ce n'est pas un agent de code. Un
    /// planificateur n'a rien à en faire.
    private static let syntheticAgentIDs: Set<String> = ["superset"]

    private func loadAgents() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = SupersetCLI.isInstalled() ? SupersetCLI.agentConfigs() : nil
            let usable = found?.filter { !Self.syntheticAgentIDs.contains($0.id) }
            DispatchQueue.main.async {
                if let usable, !usable.isEmpty {
                    agents = usable
                    normalizeAgentRef()
                    agentsUnavailable = false
                } else {
                    agentsUnavailable = true
                }
            }
        }
    }

    /// `Action.defaultAgentRef` vaut `"claude"`, qui est un **preset id** — alors que la
    /// configuration correspondante a un **UUID**. Sans normalisation, le sélecteur
    /// affichait « claude » (l'entrée de repli, chaîne brute) À CÔTÉ de « Claude »
    /// (la vraie configuration) : deux lignes pour la même chose.
    ///
    /// On bascule donc vers l'UUID dès que la liste est connue. C'est aussi le bon
    /// stockage : seul l'UUID d'une `HostAgentConfig` porte un profil de permissions,
    /// alors que le preset nu tourne avec les permissions par défaut.
    private func normalizeAgentRef() {
        guard !agents.contains(where: { $0.id == agentRef }) else { return }
        if let match = agents.first(where: { $0.preset == agentRef }) {
            agentRef = match.id
        } else if agentRef.isEmpty, let first = agents.first {
            agentRef = first.id
        }
    }

    // MARK: - Prompt

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .accessibilityLabel("Prompt envoyé à l'agent")
            Text("Texte littéral : aucune substitution n'est faite au lancement. "
                 + "Une veille qui doit connaître sa fenêtre temporelle doit la faire "
                 + "calculer par l'agent (« depuis le rapport le plus récent… »).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Erreurs et actions

    private func errorBox(_ errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(errors, id: \.self) { error in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red).font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(error).font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Barre fixe, **hors du `ScrollView`** : avec un prompt d'automation, « Enregistrer »
    /// se trouvait tout au fond et il fallait dérouler pour le retrouver.
    private var footer: some View {
        HStack(spacing: 10) {
            Button("Enregistrer") { attemptSave() }
                .keyboardShortcut(.defaultAction)
                .help("Enregistre la planification et met à jour son job launchd.")

            Button("Annuler", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            if !SchedulePaths.canInstallLaunchAgents {
                Text("En développement : la planification est enregistrée mais pas installée "
                     + "dans launchd.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// ⚠️ **Déplie les volets fautifs avant d'abandonner.** C'est la condition qui rend le
    /// pliage honnête : sinon le message d'erreur désigne un champ que rien ne montre.
    private func attemptSave() {
        showErrors = true
        let report = self.report
        guard report.isValid else {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.formUnion(invalidSections(report))
            }
            return
        }
        onSave(candidate)
    }
}
