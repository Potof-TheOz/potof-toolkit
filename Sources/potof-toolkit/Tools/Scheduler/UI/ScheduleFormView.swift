import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Formulaire de création / édition d'une planification.
///
/// **Présenté en place au centre, PAS en `.sheet`** : le dépôt n'a aucune `.sheet`, refus
/// documenté dans `RebasePanelView`.
///
/// ## La règle qui gouverne tout ce fichier
/// `validate()` ne regarde que des données locales (le dossier et le fichier de settings
/// existent-ils ?). Ce que `claude` pense du dossier — l'a-t-il déjà approuvé ? — est un
/// **avertissement non bloquant** : le fichier `~/.claude.json` peut être en retard sur
/// l'état réel, et le runner détecte de toute façon le dialogue de confiance.
///
/// ## Sections repliables, et pourquoi
/// Six volets — Identité, Dossier, Préscript, Claude, Cadence, Prompt — chacun repliable
/// et **montrant son résumé une fois fermé**. Replié, chaque volet se lit d'une ligne et
/// l'inspection d'ensemble reste possible sans dérouler deux écrans.
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
        _enabled = State(initialValue: seed.enabled)
        _folderPath = State(initialValue: seed.folderPath)
        _preScript = State(initialValue: seed.preScript)
        _model = State(initialValue: seed.action.model ?? "")
        _effort = State(initialValue: seed.action.effort ?? "")
        _settingsPath = State(initialValue: seed.action.settingsPath ?? "")
        _mcpText = State(initialValue: seed.requiredMCPServers.joined(separator: "\n"))
        _timeoutMinutes = State(initialValue: seed.timeoutMinutes)
        _recurrence = State(initialValue: seed.recurrence)
        _prompt = State(initialValue: seed.action.prompt)
        // Création : tout ouvert (cf. règle 1 de l'en-tête). Modification : on n'ouvre que
        // l'identité et le prompt, le reste se relit dans les résumés.
        _expanded = State(initialValue: draft == nil
            ? Set(FormSection.allCases)
            : [.identity, .prompt])
    }

    @ObservedObject private var store = ScheduleStore.shared

    @State private var name: String
    @State private var enabled: Bool
    @State private var folderPath: String
    @State private var preScript: String
    @State private var model: String
    @State private var effort: String
    @State private var settingsPath: String
    /// Un MCP par ligne.
    @State private var mcpText: String
    @State private var timeoutMinutes: Int
    /// Le champ accepte n'importe quel entier : on le borne à `Schedule.timeoutRange`.
    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { timeoutMinutes },
            set: { timeoutMinutes = min(max($0, Schedule.timeoutRange.lowerBound),
                                        Schedule.timeoutRange.upperBound) }
        )
    }
    @State private var recurrence: Recurrence
    @State private var prompt: String

    /// `nil` tant que `~/.claude.json` n'a pas été relu pour le dossier courant.
    @State private var trusted: Bool?
    @State private var showErrors = false
    @State private var expanded: Set<FormSection>

    /// ⭐ Tiré **une seule fois**. `candidate` est une propriété calculée : un `UUID()` à
    /// la volée en aurait produit un différent à chaque lecture, et `report` en fait deux.
    @State private var newID = UUID()

    /// Les six volets, dans l'ordre d'affichage.
    private enum FormSection: String, CaseIterable, Hashable {
        case identity, folder, preScript, claude, recurrence, prompt

        var title: String {
            switch self {
            case .identity:   return "Identité"
            case .folder:     return "Dossier"
            case .preScript:  return "Préscript"
            case .claude:     return "Claude"
            case .recurrence: return "Cadence"
            case .prompt:     return "Prompt"
            }
        }
    }

    private static func blank() -> Schedule {
        Schedule(
            name: "",
            folderPath: "",
            action: .claude(prompt: "", model: nil, effort: nil, settingsPath: nil),
            recurrence: .daily(hour: 9, minute: 0))
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un champ vide vaut « non renseigné » : `nil` dans le modèle.
    private static func optional(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    /// Les lignes vides sont ignorées ; une ligne faite d'espaces reste, pour que la
    /// validation la signale au lieu de la jeter en silence.
    private var mcpServers: [String] {
        mcpText.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : Self.trimmed($0) }
    }

    private var normalizedFolder: String {
        let path = Self.trimmed(folderPath)
        return path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
    }

    private var candidate: Schedule {
        Schedule(
            id: draft?.id ?? newID,
            name: Self.trimmed(name),
            enabled: enabled,
            folderPath: normalizedFolder,
            preScript: Self.trimmed(preScript).isEmpty ? "" : preScript,
            action: .claude(
                prompt: prompt,
                model: Self.optional(model),
                effort: Self.optional(effort),
                settingsPath: Self.optional(settingsPath).map {
                    $0.hasPrefix("~") ? ($0 as NSString).expandingTildeInPath : $0
                }),
            recurrence: recurrence,
            timeoutMinutes: timeoutMinutes,
            requiredMCPServers: mcpServers,
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
        if !report.folder.isEmpty     { result.insert(.folder) }
        if !report.claude.isEmpty     { result.insert(.claude) }
        if !report.recurrence.isEmpty { result.insert(.recurrence) }
        if !report.prompt.isEmpty     { result.insert(.prompt) }
        return result
    }

    // MARK: - Résumés des volets repliés

    private func summary(_ section: FormSection) -> String {
        switch section {
        case .identity:
            let trimmed = Self.trimmed(name)
            return (trimmed.isEmpty ? "sans nom" : trimmed) + (enabled ? "" : " · désactivée")
        case .folder:
            let path = normalizedFolder
            guard !path.isEmpty else { return "aucun dossier" }
            return (path as NSString).abbreviatingWithTildeInPath
                + (trusted == false ? " · non approuvé par Claude" : "")
        case .preScript:
            let trimmed = Self.trimmed(preScript)
            guard !trimmed.isEmpty else { return "aucun" }
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            return "\(lines.count) ligne(s) — \(lines.first ?? "")"
        case .claude:
            var parts = ["modèle \(Self.optional(model) ?? "par défaut")",
                         "effort \(Self.optional(effort) ?? "par défaut")",
                         "\(timeoutMinutes) min"]
            if Self.optional(settingsPath) != nil { parts.append("settings") }
            if !mcpServers.isEmpty { parts.append("\(mcpServers.count) MCP requis") }
            return parts.joined(separator: " · ")
        case .recurrence:
            return LaunchAgentPlist.humanDescription(recurrence)
        case .prompt:
            let trimmed = Self.trimmed(prompt)
            guard !trimmed.isEmpty else { return "vide" }
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1,
                                          omittingEmptySubsequences: false).first ?? ""
            return "\(trimmed.count) caractères — \(firstLine)"
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

                    disclosure(.identity, invalid: invalid) { identityControls }
                    disclosure(.folder, invalid: invalid) { folderControls }
                    disclosure(.preScript, invalid: invalid) { preScriptEditor }
                    disclosure(.claude, invalid: invalid) { claudeControls }
                    disclosure(.recurrence, invalid: invalid) {
                        RecurrencePicker(recurrence: $recurrence)
                    }
                    disclosure(.prompt, invalid: invalid, separator: false) { promptEditor }

                    if showErrors && !report.all.isEmpty { errorBox(report.all) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .onAppear(perform: refreshTrust)
        .onChange(of: folderPath) { _ in refreshTrust() }
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

    // MARK: - Identité

    private var identityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Relevé Sentry — Shopify-Apps", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .accessibilityLabel("Nom de la planification")
            Toggle("Active", isOn: $enabled)
                .toggleStyle(.checkbox)
                .help("Désactivée, la planification ne part plus d'elle-même ; "
                      + "« Lancer maintenant » reste possible.")
        }
    }

    // MARK: - Dossier

    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("/Users/…/mon-projet", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Dossier où la session est lancée")
                Button("Choisir…") {
                    if let path = Self.choose(directories: true, startingAt: normalizedFolder) {
                        folderPath = path
                    }
                }
                .help("Choisir le dossier dans lequel le préscript puis claude sont lancés.")
            }
            // Non bloquant : `~/.claude.json` peut être en retard sur l'état réel.
            if trusted == false && !normalizedFolder.isEmpty {
                warning("Claude n'a jamais approuvé ce dossier : le run échouera. "
                        + "Ouvrez-le une fois dans Claude Launcher.")
            }
        }
    }

    /// Relit `~/.claude.json` hors du thread principal : le fichier grossit avec
    /// l'historique des projets et ne doit pas geler la frappe.
    private func refreshTrust() {
        let path = normalizedFolder
        guard path.hasPrefix("/") else {
            trusted = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClaudeInvocation.isTrusted(
                folderPath: path,
                claudeJSON: try? Data(contentsOf: ClaudeInvocation.claudeJSONURL))
            DispatchQueue.main.async {
                // Le champ a pu changer entre-temps : on ne publie que la réponse à jour.
                if normalizedFolder == path { trusted = result }
            }
        }
    }

    // MARK: - Préscript

    private var preScriptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $preScript)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .accessibilityLabel("Préscript exécuté avant claude")
            Text("Exécuté avec $SHELL -l -i -c dans le dossier. "
                 + "Un code de sortie ≠ 0 annule le run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Claude

    private var claudeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Modèle") {
                TextField("défaut de claude (ex. haiku, sonnet, opus)", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .accessibilityLabel("Modèle passé à claude --model")
            }
            labeled("Effort") {
                Picker("", selection: $effort) {
                    Text("défaut de claude").tag("")
                    ForEach(Schedule.effortLevels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Effort passé à claude --effort")
            }
            labeled("Settings") {
                HStack(spacing: 8) {
                    TextField("facultatif : fichier JSON de settings", text: $settingsPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .accessibilityLabel("Fichier de settings fusionné dans ceux du run")
                    Button("Choisir…") {
                        if let path = Self.choose(directories: false,
                                                  startingAt: Self.trimmed(settingsPath)) {
                            settingsPath = path
                        }
                    }
                    .help("Choisir un fichier de settings claude (permissions, hooks…). "
                          + "Il est fusionné avec le hook Stop du run.")
                }
            }
            labeled("MCP requis") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $mcpText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 300, height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        .accessibilityLabel("MCP requis, un par ligne")
                    Text("Un par ligne, nommés comme dans « claude mcp list ». "
                         + "S'il en manque un, le run échoue avant de lancer claude.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            labeled("Délai") {
                // Champ saisissable + pas de 5 : avec un pas de 1 sur 1…240, passer de 60 à 5
                // demandait 55 clics (vu en recette : on s'arrête à 39).
                HStack(spacing: 6) {
                    TextField("", value: timeoutBinding, format: .number)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Stepper("", value: timeoutBinding, in: Schedule.timeoutRange, step: 5)
                        .labelsHidden()
                    Text("min").foregroundStyle(.secondary)
                }
                .help("Au-delà, la session est tuée et le run finit en « délai dépassé ».")
                .accessibilityLabel("Délai maximal de la session, en minutes")
            }
        }
    }

    private func labeled<Content: View>(_ label: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
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
                .accessibilityLabel("Prompt envoyé à claude")
            Text("Texte littéral : aucune substitution n'est faite au lancement. "
                 + "Une veille qui doit connaître sa fenêtre temporelle doit la faire "
                 + "calculer par claude (« depuis le rapport le plus récent… »).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fragments

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.system(size: 11))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func choose(directories: Bool, startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choisir"
        if directories {
            panel.message = "Choisissez le dossier où lancer claude"
        } else {
            panel.message = "Choisissez un fichier de settings claude"
            panel.allowedContentTypes = [.json]
        }
        if !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            panel.directoryURL = directories ? url : url.deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
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
