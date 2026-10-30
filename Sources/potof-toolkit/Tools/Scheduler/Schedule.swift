import Foundation

/// Une **planification** : où (`folderPath`), quoi préparer (`preScript`), quoi lancer
/// (`action`), quand (`recurrence`), et dans quelles limites (`timeoutMinutes`,
/// `requiredMCPServers`).
///
/// Écrite UNIQUEMENT par la GUI dans `schedules.json` (le mode headless est lecteur
/// seul) — cet invariant supprime toute course lecture-modification-écriture entre les
/// deux process. Corollaire : **pas de `lastRunAt` ici**, il est dérivé du JSONL des runs.
struct Schedule: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var enabled: Bool
    /// OÙ le run part : chemin absolu d'un dossier que `claude` a déjà approuvé.
    var folderPath: String
    /// Script shell exécuté dans le dossier avant `claude`. `""` = aucun.
    var preScript: String
    /// CE QUE le run lance.
    var action: Action
    /// QUAND il part.
    var recurrence: Recurrence
    /// Durée maximale de la session `claude`, en minutes (`timeoutRange`).
    var timeoutMinutes: Int
    /// Noms des MCP tels que les écrit `claude mcp list` (ex. `plugin:sentry-mcp:sentry`).
    var requiredMCPServers: [String]
    var createdAt: Date
    var updatedAt: Date

    static let defaultTimeoutMinutes = 60
    static let timeoutRange = 1...240

    /// Valeurs proposées pour `--effort` ; `nil` = défaut de `claude`.
    static let effortLevels = ["low", "medium", "high", "xhigh"]

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        folderPath: String,
        preScript: String = "",
        action: Action,
        recurrence: Recurrence,
        timeoutMinutes: Int = Schedule.defaultTimeoutMinutes,
        requiredMCPServers: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.folderPath = folderPath
        self.preScript = preScript
        self.action = action
        self.recurrence = recurrence
        self.timeoutMinutes = timeoutMinutes
        self.requiredMCPServers = requiredMCPServers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Label launchd — **TOUJOURS** ce préfixe. C'est la seule chose qui autorise
    /// `SchedulerService` à supprimer un fichier de `~/Library/LaunchAgents` (cf. la
    /// règle non négociable du §6.4 : jamais de suppression par glob).
    var launchAgentLabel: String {
        "com.potof.toolkit.schedule.\(id.uuidString.lowercased())"
    }

    /// Longueur minimale d'un prompt. Un prompt d'un mot lancé toutes les 6 h, c'est une
    /// session payante qui tourne dans le vide.
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
        var folder: [String] = []
        var claude: [String] = []
        var prompt: [String] = []
        var recurrence: [String] = []

        /// Ordre de lecture = ordre des volets du formulaire.
        var all: [String] { identity + folder + claude + recurrence + prompt }
        var isValid: Bool { all.isEmpty }
    }

    /// Local : aucun appel réseau, aucun `claude`. Seule l'existence du dossier et du
    /// fichier de settings est vérifiée sur disque. L'approbation du dossier par `claude`
    /// n'en fait pas partie : le formulaire l'affiche en avertissement NON bloquant, et le
    /// runner la détecte de toute façon.
    func validationReport(existingNames: Set<String>) -> ValidationReport {
        var report = ValidationReport()
        let fm = FileManager.default

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            report.identity.append("Le nom est obligatoire.")
        } else if existingNames.contains(trimmedName) {
            report.identity.append("Une autre planification porte déjà le nom « \(trimmedName) ».")
        }

        var isDirectory: ObjCBool = false
        if folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.folder.append("Le dossier est obligatoire.")
        } else if !folderPath.hasPrefix("/") {
            report.folder.append("Le chemin du dossier doit être absolu.")
        } else if !fm.fileExists(atPath: folderPath, isDirectory: &isDirectory)
                    || !isDirectory.boolValue {
            report.folder.append("Dossier introuvable : \(folderPath).")
        }

        if !Self.timeoutRange.contains(timeoutMinutes) {
            report.claude.append("Le délai doit être compris entre \(Self.timeoutRange.lowerBound) "
                                 + "et \(Self.timeoutRange.upperBound) minutes.")
        }
        if let effort = action.effort, !Self.effortLevels.contains(effort) {
            report.claude.append("Effort inconnu : « \(effort) ».")
        }
        if let settingsPath = action.settingsPath,
           !fm.fileExists(atPath: settingsPath, isDirectory: &isDirectory) || isDirectory.boolValue {
            report.claude.append("Fichier de settings introuvable : \(settingsPath).")
        }
        if requiredMCPServers.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            report.claude.append("Un MCP requis porte un nom vide.")
        }

        let trimmedPrompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            report.prompt.append("Le prompt est obligatoire.")
        } else if trimmedPrompt.count < Self.minimumPromptLength {
            report.prompt.append(
                "Le prompt fait \(trimmedPrompt.count) caractères ; "
                + "il en faut au moins \(Self.minimumPromptLength).")
        }

        report.recurrence = recurrence.validationErrors()
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
/// **Un seul cas, et le discriminant `kind` existe malgré ça** : c'est ce qui a permis de
/// remplacer `supersetAgent` par `claude` sans ambiguïté sur disque, et ce qui permettra
/// d'ajouter un autre cas plus tard. Ne PAS aplatir `prompt` à la racine de `Schedule`.
enum Action: Hashable, Codable {
    /// Session interactive `claude` dans le dossier : `--model`, `--effort` et un fichier
    /// de `--settings` fusionné dans les settings du run, tous facultatifs.
    case claude(prompt: String, model: String?, effort: String?, settingsPath: String?)

    /// Le prompt est une **chaîne littérale** : aucune substitution de jeton, jamais. Il
    /// n'est jamais interprété par un shell (argument positionnel après `--`).
    var prompt: String {
        switch self { case .claude(let prompt, _, _, _): return prompt }
    }
    var model: String? {
        switch self { case .claude(_, let model, _, _): return model }
    }
    var effort: String? {
        switch self { case .claude(_, _, let effort, _): return effort }
    }
    var settingsPath: String? {
        switch self { case .claude(_, _, _, let settingsPath): return settingsPath }
    }

    // Codable à la main : la synthèse Swift produirait `{"claude":{"prompt":…}}`, dont la
    // stabilité n'est pas un contrat du langage.
    private enum CodingKeys: String, CodingKey { case kind, prompt, model, effort, settingsPath }
    private enum Kind: String, Codable { case claude }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .claude:
            self = .claude(
                prompt: try container.decode(String.self, forKey: .prompt),
                model: try container.decodeIfPresent(String.self, forKey: .model),
                effort: try container.decodeIfPresent(String.self, forKey: .effort),
                settingsPath: try container.decodeIfPresent(String.self, forKey: .settingsPath))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claude(let prompt, let model, let effort, let settingsPath):
            try container.encode(Kind.claude, forKey: .kind)
            try container.encode(prompt, forKey: .prompt)
            // `null` explicite si absent : le fichier montre que le champ existe.
            try container.encode(model, forKey: .model)
            try container.encode(effort, forKey: .effort)
            try container.encode(settingsPath, forKey: .settingsPath)
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
