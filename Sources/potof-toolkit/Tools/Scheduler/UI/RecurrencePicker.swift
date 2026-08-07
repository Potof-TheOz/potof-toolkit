import SwiftUI

/// Sélecteur de cadence — **lot L4bis**.
///
/// Ne propose **que** `Recurrence.allowedHourSteps` et `Recurrence.allowedMonthDays`, avec
/// un `.help()` qui explique pourquoi dans les deux cas :
/// - un intervalle non-diviseur de 24 (5, 7, 9…) n'a **aucune** expression calendaire
///   quotidienne — le motif ne se referme pas sur 24 h, donc launchd ne sait pas l'écrire ;
/// - au-delà du 28, launchd **ne clampe pas** : l'exécution est simplement sautée les mois
///   courts, silencieusement.
///
/// Mapping d'affichage **L M M J V S D** → `1, 2, 3, 4, 5, 6, 0` (le modèle indexe
/// 0 = dimanche, comme launchd ; `Calendar`, lui, indexe 1 = dimanche — la conversion
/// vit dans `LaunchAgentPlist`, surtout pas ici).
struct RecurrencePicker: View {

    @Binding var recurrence: Recurrence

    init(recurrence: Binding<Recurrence>) {
        self._recurrence = recurrence
    }

    private enum Kind: String, CaseIterable, Identifiable {
        case everyNHours = "Toutes les X heures"
        case daily = "Quotidien"
        case weekly = "Hebdomadaire"
        case monthly = "Mensuel"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch recurrence {
        case .everyNHours: return .everyNHours
        case .daily:       return .daily
        case .weekly:      return .weekly
        case .monthly:     return .monthly
        }
    }

    /// Heure/minute courantes, quelle que soit la variante — sert à **conserver l'horaire**
    /// quand on change de type de cadence.
    private var time: (hour: Int, minute: Int) {
        switch recurrence {
        case .everyNHours(_, let anchor, let minute): return (anchor, minute)
        case .daily(let hour, let minute):            return (hour, minute)
        case .weekly(_, let hour, let minute):        return (hour, minute)
        case .monthly(_, let hour, let minute):       return (hour, minute)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Type", selection: Binding(get: { kind }, set: switchKind)) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch recurrence {
            case .everyNHours(let hours, let anchor, let minute):
                everyNHoursControls(hours: hours, anchor: anchor, minute: minute)
            case .daily(let hour, let minute):
                timeRow(label: "à", hour: hour, minute: minute) { h, m in
                    recurrence = .daily(hour: h, minute: m)
                }
            case .weekly(let weekdays, let hour, let minute):
                weeklyControls(weekdays: weekdays, hour: hour, minute: minute)
            case .monthly(let day, let hour, let minute):
                monthlyControls(day: day, hour: hour, minute: minute)
            }

            Text(LaunchAgentPlist.humanDescription(recurrence))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Changer de type conserve l'horaire déjà saisi — retomber sur 00:00 à chaque clic
    /// est le genre de détail qui fait ressaisir trois fois.
    private func switchKind(_ new: Kind) {
        let (hour, minute) = time
        switch new {
        case .everyNHours:
            recurrence = .everyNHours(hours: 6, anchorHour: hour, minute: minute)
        case .daily:
            recurrence = .daily(hour: hour, minute: minute)
        case .weekly:
            recurrence = .weekly(weekdays: [1, 2, 3, 4, 5], hour: hour, minute: minute)
        case .monthly:
            recurrence = .monthly(day: 1, hour: hour, minute: minute)
        }
    }

    // MARK: - Variantes

    private func everyNHoursControls(hours: Int, anchor: Int, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Toutes les").font(.system(size: 12))
                Picker("", selection: Binding(
                    get: { hours },
                    set: { recurrence = .everyNHours(hours: $0, anchorHour: anchor, minute: minute) }
                )) {
                    ForEach(Recurrence.allowedHourSteps, id: \.self) { Text("\($0) h").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                .help("Seuls les diviseurs de 24 sont proposés : un intervalle de 5 ou 7 heures "
                      + "n'a aucune expression calendaire quotidienne — le motif ne se referme "
                      + "pas sur 24 h, et launchd ne saurait pas l'écrire.")
                Spacer()
            }
            timeRow(label: "à partir de", hour: anchor, minute: minute) { h, m in
                recurrence = .everyNHours(hours: hours, anchorHour: h, minute: m)
            }
        }
    }

    private func weeklyControls(weekdays: Set<Int>, hour: Int, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(zip(["L", "M", "M", "J", "V", "S", "D"],
                                  [1, 2, 3, 4, 5, 6, 0])), id: \.1) { symbol, index in
                    let selected = weekdays.contains(index)
                    Button {
                        var updated = weekdays
                        if selected { updated.remove(index) } else { updated.insert(index) }
                        recurrence = .weekly(weekdays: updated, hour: hour, minute: minute)
                    } label: {
                        Text(symbol)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 24)
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(Self.weekdayNames[index])
                    .accessibilityLabel(Self.weekdayNames[index])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }
            timeRow(label: "à", hour: hour, minute: minute) { h, m in
                recurrence = .weekly(weekdays: weekdays, hour: h, minute: m)
            }
        }
    }

    private func monthlyControls(day: Int, hour: Int, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Le").font(.system(size: 12))
                Picker("", selection: Binding(
                    get: { day },
                    set: { recurrence = .monthly(day: $0, hour: hour, minute: minute) }
                )) {
                    ForEach(Array(Recurrence.allowedMonthDays), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                .help("Plafonné au 28 : launchd ne ramène pas un jour trop grand au dernier "
                      + "jour du mois, il saute simplement l'exécution en février, avril, juin, "
                      + "septembre et novembre — sans le moindre message.")
                Text("du mois").font(.system(size: 12))
                Spacer()
            }
            timeRow(label: "à", hour: hour, minute: minute) { h, m in
                recurrence = .monthly(day: day, hour: h, minute: m)
            }
        }
    }

    // MARK: - Heure

    private func timeRow(label: String, hour: Int, minute: Int,
                         set: @escaping (Int, Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12))
            DatePicker("", selection: Binding(
                get: { Self.date(hour: hour, minute: minute) },
                set: { newValue in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                    set(parts.hour ?? hour, parts.minute ?? minute)
                }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .frame(width: 90)
            .accessibilityLabel("Heure de déclenchement")
            Spacer()
        }
    }

    /// Date arbitraire (aujourd'hui) portant l'heure voulue : le `DatePicker` ne manipule
    /// que `.hourAndMinute`, le jour n'est jamais lu.
    private static func date(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private static let weekdayNames =
        ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
}
