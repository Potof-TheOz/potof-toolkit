import Foundation

/// Une **planification** : ce qu'on lance (`action`), quand (`recurrence`), où (`target`).
///
/// Écrite UNIQUEMENT par la GUI dans `schedules.json` (le mode headless est lecteur
/// seul) — cet invariant supprime toute course lecture-modification-écriture entre les
/// deux process. Corollaire : **pas de `lastRunAt` ici**, il est dérivé du JSONL des runs.
struct Schedule: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var enabled: Bool
    /// CE QUE le run lance.
    var action: Action
    /// QUAND il part.
    var recurrence: Recurrence
    /// OÙ il part.
    var target: Target
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        action: Action,
        recurrence: Recurrence,
        target: Target,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.action = action
        self.recurrence = recurrence
        self.target = target
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Label launchd — **TOUJOURS** ce préfixe. C'est la seule chose qui autorise
    /// `SchedulerService` à supprimer un fichier de `~/Library/LaunchAgents` (cf. la
    /// règle non négociable du §6.4 : jamais de suppression par glob).
    var launchAgentLabel: String {
        "com.potof.toolkit.schedule.\(id.uuidString.lowercased())"
    }

    /// Longueur minimale d'un prompt. Un prompt d'un mot lancé toutes les 6 h, c'est un
    /// agent payant qui tourne dans le vide.
    static let minimumPromptLength = 20

    /// Erreurs **regroupées par volet du formulaire**.
    ///
    /// ⭐ `validate(existingNames:)` n'en est que l'aplatissement : **une seule source de
    /// vérité**. Le formulaire à sections repliables a besoin du découpage pour déplier
    /// exactement les volets fautifs — sans lui, « Le prompt est obligatoire » s'afficherait
    /// au-dessus d'une section fermée et on chercherait où. Réimplémenter les règles côté
    /// vue pour obtenir ce découpage les aurait fait diverger au premier changement.
    struct ValidationReport {
        var identity: [String] = []
        var agent: [String] = []
        var prompt: [String] = []
        var recurrence: [String] = []
        var target: [String] = []

        /// Ordre de lecture = ordre des volets du formulaire.
        var all: [String] { identity + agent + prompt + recurrence + target }
        var isValid: Bool { all.isEmpty }
    }

    /// Purement local : aucun appel réseau, aucune vérification d'existence côté Superset
    /// (le formulaire les fait à part, en avertissements NON bloquants — une liste
    /// illisible parce que le host est éteint ne doit jamais empêcher d'enregistrer).
    func validationReport(existingNames: Set<String>) -> ValidationReport {
        var report = ValidationReport()

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            report.identity.append("Le nom est obligatoire.")
        } else if existingNames.contains(trimmedName) {
            report.identity.append("Une autre planification porte déjà le nom « \(trimmedName) ».")
        }

        switch action {
        case .supersetAgent(let agentRef, _, let prompt):
            if agentRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.agent.append("Aucun agent sélectionné.")
            }
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPrompt.isEmpty {
                report.prompt.append("Le prompt est obligatoire.")
            } else if trimmedPrompt.count < Self.minimumPromptLength {
                report.prompt.append(
                    "Le prompt fait \(trimmedPrompt.count) caractères ; "
                    + "il en faut au moins \(Self.minimumPromptLength).")
            }
        }

        report.recurrence = recurrence.validationErrors()
        report.target = target.validationErrors()
        return report
    }

    /// Messages d'erreur **en français**, tableau vide = valide.
    func validate(existingNames: Set<String>) -> [String] {
        validationReport(existingNames: existingNames).all
    }
}

// MARK: - Action

/// Ce qu'un run **lance**.
///
/// **Un seul cas en v1, et le discriminant `kind` existe malgré ça** : c'est ce qui
/// permettra d'ajouter un `claudeHeadless` (ou autre) sans migrer un seul fichier sur
/// disque. Ne PAS aplatir `prompt`/`agentRef` à la racine de `Schedule` — c'est
/// exactement le repli qu'on paie une fois pour ne jamais le repayer.
enum Action: Hashable, Codable {
    /// `superset agents create --workspace <id> --agent <ref> [--effort <e>] --prompt <p>`.
    case supersetAgent(agentRef: String, effort: String?, prompt: String)

    /// Preset par défaut. Un `agentRef` est soit un preset (`claude`, `codex`…), soit
    /// l'UUID d'une `HostAgentConfig` — la CLI accepte les deux sur `--agent`. ⚠️ Seul
    /// l'UUID peut porter un **profil de permissions** : un agent quotidien non
    /// surveillé sur le preset nu tourne en permissions par défaut.
    static let defaultAgentRef = "claude"

    var agentRef: String {
        switch self { case .supersetAgent(let ref, _, _): return ref }
    }
    var effort: String? {
        switch self { case .supersetAgent(_, let effort, _): return effort }
    }
    /// Le prompt est une **chaîne littérale** : aucune substitution de jeton, jamais.
    /// Une automation à fenêtre temporelle fait calculer sa fenêtre par l'agent.
    var prompt: String {
        switch self { case .supersetAgent(_, _, let prompt): return prompt }
    }

    // Codable à la main : la synthèse Swift produirait `{"supersetAgent":{"_0":…}}`,
    // illisible et dont la stabilité n'est pas un contrat du langage.
    private enum CodingKeys: String, CodingKey { case kind, agentRef, effort, prompt }
    private enum Kind: String, Codable { case supersetAgent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .supersetAgent:
            self = .supersetAgent(
                agentRef: try container.decodeIfPresent(String.self, forKey: .agentRef)
                    ?? Self.defaultAgentRef,
                effort: try container.decodeIfPresent(String.self, forKey: .effort),
                prompt: try container.decode(String.self, forKey: .prompt)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .supersetAgent(let agentRef, let effort, let prompt):
            try container.encode(Kind.supersetAgent, forKey: .kind)
            try container.encode(agentRef, forKey: .agentRef)
            try container.encode(effort, forKey: .effort)   // `null` explicite si absent
            try container.encode(prompt, forKey: .prompt)
        }
    }
}

// MARK: - Recurrence

/// Périodicité, traduite en `StartCalendarInterval` par `LaunchAgentPlist`.
/// Pas de cron, pas de RRULE, et **surtout pas `StartInterval`** (minuteur relatif à la
/// mise en charge : il redémarre à chaque login et à chaque réinstallation du plist).
enum Recurrence: Hashable, Codable {
    /// `hours` doit être un **diviseur de 24** : sinon le motif ne se referme pas sur
    /// 24 h et n'a aucune expression calendaire quotidienne.
    case everyNHours(hours: Int, anchorHour: Int, minute: Int)
    case daily(hour: Int, minute: Int)
    /// `0` = dimanche … `6` = samedi.
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)
    /// Jour plafonné à 28 : launchd **ne clampe pas**, `Day: 31` ne se déclenche jamais
    /// en février, avril, juin, septembre ni novembre — silencieusement.
    case monthly(day: Int, hour: Int, minute: Int)

    /// Contrat partagé : le picker ne propose que ça, et l'expansion plist ne traduit
    /// que ça.
    static let allowedHourSteps: [Int] = [1, 2, 3, 4, 6, 8, 12]
    static let allowedMonthDays: ClosedRange<Int> = 1...28
    static let allowedWeekdays: ClosedRange<Int> = 0...6

    func validationErrors() -> [String] {
        var errors: [String] = []
        switch self {
        case .everyNHours(let hours, let anchorHour, let minute):
            if !Self.allowedHourSteps.contains(hours) {
                errors.append(
                    "Un intervalle de \(hours) h ne se referme pas sur 24 h. "
                    + "Valeurs possibles : \(Self.allowedHourSteps.map(String.init).joined(separator: ", ")).")
            }
            errors.append(contentsOf: Self.timeErrors(hour: anchorHour, minute: minute))
        case .daily(let hour, let minute):
            errors.append(contentsOf: Self.timeErrors(hour: hour, minute: minute))
        case .weekly(let weekdays, let hour, let minute):
            if weekdays.isEmpty {
                errors.append("Sélectionnez au moins un jour de la semaine.")
            } else if let bad = weekdays.first(where: { !Self.allowedWeekdays.contains($0) }) {
                errors.append("Jour de semaine invalide : \(bad).")
            }
            errors.append(contentsOf: Self.timeErrors(hour: hour, minute: minute))
        case .monthly(let day, let hour, let minute):
            if !Self.allowedMonthDays.contains(day) {
                errors.append(
                    "Le jour du mois doit être compris entre 1 et 28 "
                    + "(au-delà, l'exécution serait sautée les mois courts).")
            }
            errors.append(contentsOf: Self.timeErrors(hour: hour, minute: minute))
        }
        return errors
    }

    private static func timeErrors(hour: Int, minute: Int) -> [String] {
        var errors: [String] = []
        if !(0...23).contains(hour) { errors.append("L'heure doit être comprise entre 0 et 23.") }
        if !(0...59).contains(minute) { errors.append("Les minutes doivent être comprises entre 0 et 59.") }
        return errors
    }

    private enum CodingKeys: String, CodingKey {
        case kind, hours, anchorHour, minute, hour, weekdays, day
    }
    private enum Kind: String, Codable { case everyNHours, daily, weekly, monthly }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        switch try container.decode(Kind.self, forKey: .kind) {
        case .everyNHours:
            self = .everyNHours(
                hours: try container.decode(Int.self, forKey: .hours),
                anchorHour: try container.decodeIfPresent(Int.self, forKey: .anchorHour) ?? 0,
                minute: minute)
        case .daily:
            self = .daily(hour: try container.decode(Int.self, forKey: .hour), minute: minute)
        case .weekly:
            self = .weekly(
                weekdays: Set(try container.decode([Int].self, forKey: .weekdays)),
                hour: try container.decode(Int.self, forKey: .hour),
                minute: minute)
        case .monthly:
            self = .monthly(
                day: try container.decode(Int.self, forKey: .day),
                hour: try container.decode(Int.self, forKey: .hour),
                minute: minute)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyNHours(let hours, let anchorHour, let minute):
            try container.encode(Kind.everyNHours, forKey: .kind)
            try container.encode(hours, forKey: .hours)
            try container.encode(anchorHour, forKey: .anchorHour)
            try container.encode(minute, forKey: .minute)
        case .daily(let hour, let minute):
            try container.encode(Kind.daily, forKey: .kind)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekdays, let hour, let minute):
            try container.encode(Kind.weekly, forKey: .kind)
            // Trié : un Set n'a pas d'ordre, et un JSON qui change à chaque écriture
            // rendrait le fichier illisible en diff.
            try container.encode(weekdays.sorted(), forKey: .weekdays)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .monthly(let day, let hour, let minute):
            try container.encode(Kind.monthly, forKey: .kind)
            try container.encode(day, forKey: .day)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        }
    }
}

// MARK: - Target

/// Où l'agent est lancé.
///
/// ⭐ On stocke les **COORDONNÉES** du workspace (`projectID` + `workspaceName`), jamais
/// son `workspaceID` : un workspace supprimé puis recréé garde son nom mais change d'id.
/// La résolution se refait donc **à chaque run**.
enum Target: Hashable, Codable {
    case permanentWorkspace(projectID: String, projectName: String, workspaceName: String,
                            branch: String, baseBranch: String?, refreshWorktree: Bool)
    case freshWorkspace(projectID: String, projectName: String,
                        namePrefix: String, branchPrefix: String, baseBranch: String?)

    /// Au-delà de ce nombre de workspaces portant le `namePrefix`, un run `freshWorkspace`
    /// abandonne en `skipped`. On ne supprime **jamais** automatiquement : détruire un
    /// workspace où un agent travaille encore serait destructif.
    static let freshWorkspaceCap = 20

    // MARK: - Nommage du mode « workspace neuf » — GELÉ ICI, et pas ailleurs

    /// ⭐ Trois appelants doivent produire **exactement** la même chaîne : l'aperçu du
    /// formulaire, le `--dry-run` et le run réel. Si le runner en réimplémentait une
    /// variante, l'aperçu mentirait sur ce qui sera créé — et personne ne le verrait
    /// avant d'avoir un workspace de trop.
    ///
    /// Locale **`en_US_POSIX`** imposée : un format construit avec la locale de
    /// l'utilisateur produirait des noms différents selon la machine, et le comptage par
    /// préfixe du plafond (`freshWorkspaceCap`) ne retrouverait plus ses petits.
    /// Fuseau **local** en revanche : une planification « à 10:00 » parle heure locale.
    /// ⚠️ **Les secondes sont là pour une raison, ne pas les retirer.** Superset autorise
    /// deux workspaces **homonymes** dans un même projet (vérifié). Avec une granularité à
    /// la minute, deux runs rapprochés — un « Lancer maintenant » cliqué deux fois —
    /// fabriquaient deux workspaces au nom identique, et la résolution par nom en
    /// retrouvait un au hasard : le second agent partait dans le worktree du premier
    /// pendant que le second workspace restait vide.
    static func freshWorkspaceName(prefix: String, date: Date) -> String {
        "\(prefix) \(format(date, "yyyy-MM-dd HH:mm:ss"))"
    }

    static func freshWorkspaceBranch(prefix: String, date: Date) -> String {
        "\(slug(prefix))-\(format(date, "yyyy-MM-dd-HHmmss"))"
    }

    /// Préfixe de comparaison du plafond : tout workspace dont le nom commence par ça
    /// compte. Doit rester cohérent avec `freshWorkspaceName`.
    static func freshWorkspaceNamePrefix(_ prefix: String) -> String { "\(prefix) " }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Slug de branche : accents dépliés puis retirés, minuscules, tout ce qui n'est ni
    /// `[a-z0-9]` ni `-` remplacé par `-`. « Relève Sentry » → « releve-sentry ».
    /// Une branche git accepte bien plus que ça, mais le sous-ensemble strict évite
    /// d'avoir à raisonner sur les caractères que git refuse (`~`, `^`, `:`, `..`, etc.).
    private static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = folded.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        // Réduit les tirets consécutifs et rogne ceux des extrémités.
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true)
        return collapsed.joined(separator: "-")
    }

    var projectID: String {
        switch self {
        case .permanentWorkspace(let id, _, _, _, _, _): return id
        case .freshWorkspace(let id, _, _, _, _): return id
        }
    }
    var projectName: String {
        switch self {
        case .permanentWorkspace(_, let name, _, _, _, _): return name
        case .freshWorkspace(_, let name, _, _, _): return name
        }
    }
    var baseBranch: String? {
        switch self {
        case .permanentWorkspace(_, _, _, _, let base, _): return base
        case .freshWorkspace(_, _, _, _, let base): return base
        }
    }

    /// Résumé d'une ligne, **partagé** par le détail et par le volet « Cible » replié du
    /// formulaire. Une seule formulation : deux copies auraient divergé au premier champ
    /// ajouté. Tolère les valeurs vides — le formulaire l'affiche pendant la saisie.
    var summary: String {
        switch self {
        case .permanentWorkspace(_, let projectName, let workspaceName, let branch, _, let refresh):
            let workspace = workspaceName.isEmpty ? "(à choisir)" : workspaceName
            return placeholderProject(projectName)
                + " · workspace « \(workspace) »"
                + (branch.isEmpty ? "" : " (\(branch))")
                + (refresh ? " · rafraîchi avant chaque run" : "")
        case .freshWorkspace(_, let projectName, let namePrefix, _, _):
            let prefix = namePrefix.isEmpty ? "(préfixe à définir)" : namePrefix
            return placeholderProject(projectName)
                + " · nouveau workspace « \(prefix) … » à chaque run"
        }
    }

    private func placeholderProject(_ name: String) -> String {
        name.isEmpty ? "(projet à choisir)" : name
    }

    func validationErrors() -> [String] {
        var errors: [String] = []
        if projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Aucun projet Superset sélectionné.")
        }
        switch self {
        case .permanentWorkspace(_, _, let workspaceName, let branch, _, let refresh):
            if workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Le nom du workspace est obligatoire.")
            }
            if branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Exigée même quand le workspace existe déjà : sans elle, le jour où il
                // est supprimé, le run ne saurait pas le recréer et échouerait à 10:00
                // au lieu d'échouer ici, tout de suite, devant quelqu'un.
                errors.append("La branche est obligatoire (elle sert à recréer le workspace "
                              + "s'il venait à disparaître).")
            }
            if refresh && baseBranch?.isEmpty != false {
                errors.append(
                    "Le rafraîchissement du worktree exige une branche de base "
                    + "(c'est sur elle que le `reset --hard` est fait).")
            }
        case .freshWorkspace(_, _, let namePrefix, _, _):
            // `branchPrefix` est FACULTATIF : vide, on réutilise le préfixe de nom
            // (cf. `freshWorkspaceBranch`). `baseBranch` l'est aussi — vide, le drapeau
            // `--base-branch` n'est pas transmis et Superset prend la branche de base du
            // projet, ce qui est le cas nominal.
            if namePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Le préfixe de nom est obligatoire "
                              + "(il sert aussi à compter le plafond de workspaces).")
            }
        }
        return errors
    }

    private enum CodingKeys: String, CodingKey {
        case kind, projectID, projectName, workspaceName, branch, baseBranch,
             refreshWorktree, namePrefix, branchPrefix
    }
    private enum Kind: String, Codable { case permanentWorkspace, freshWorkspace }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let projectID = try container.decode(String.self, forKey: .projectID)
        let projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        let baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .permanentWorkspace:
            self = .permanentWorkspace(
                projectID: projectID,
                projectName: projectName,
                workspaceName: try container.decode(String.self, forKey: .workspaceName),
                branch: try container.decode(String.self, forKey: .branch),
                baseBranch: baseBranch,
                refreshWorktree: try container.decodeIfPresent(Bool.self, forKey: .refreshWorktree) ?? false)
        case .freshWorkspace:
            self = .freshWorkspace(
                projectID: projectID,
                projectName: projectName,
                namePrefix: try container.decode(String.self, forKey: .namePrefix),
                branchPrefix: try container.decode(String.self, forKey: .branchPrefix),
                baseBranch: baseBranch)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permanentWorkspace(let projectID, let projectName, let workspaceName,
                                 let branch, let baseBranch, let refreshWorktree):
            try container.encode(Kind.permanentWorkspace, forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
            try container.encode(projectName, forKey: .projectName)
            try container.encode(workspaceName, forKey: .workspaceName)
            try container.encode(branch, forKey: .branch)
            try container.encode(baseBranch, forKey: .baseBranch)
            try container.encode(refreshWorktree, forKey: .refreshWorktree)
        case .freshWorkspace(let projectID, let projectName, let namePrefix,
                             let branchPrefix, let baseBranch):
            try container.encode(Kind.freshWorkspace, forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
            try container.encode(projectName, forKey: .projectName)
            try container.encode(namePrefix, forKey: .namePrefix)
            try container.encode(branchPrefix, forKey: .branchPrefix)
            try container.encode(baseBranch, forKey: .baseBranch)
        }
    }
}
