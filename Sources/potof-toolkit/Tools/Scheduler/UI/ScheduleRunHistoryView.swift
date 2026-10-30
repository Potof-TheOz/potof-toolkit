import SwiftUI

/// Historique des runs d'une planification.
///
/// Alimenté par `ScheduleStore.runs`, lui-même reconstruit à chaque écriture du JSONL par
/// le tail (`DispatchSource` vnode). Un run déclenché par **launchd**, dans un autre
/// process, apparaît donc ici sans que l'app ait rien à demander.
///
/// ⚠️ Deux règles d'affichage qui ne sont pas cosmétiques :
/// - `completed` s'écrit « terminé », **jamais** « réussi ». La session a rendu la main
///   (hook `Stop` puis `/exit`) ; ce qu'elle a produit, le runner ne le juge pas. Un
///   historique tout vert ne prouve que des sessions menées à leur terme.
/// - `skipped` est **orange**, pas rouge : c'est un garde-fou qui a joué (run déjà en
///   cours, planification désactivée), pas une panne.
struct ScheduleRunHistoryView: View {

    let scheduleID: UUID
    /// Appelé après la sélection d'une ligne : l'appelant bascule sur l'onglet « Session ».
    let onOpen: (RunRecord) -> Void

    @ObservedObject private var store = ScheduleStore.shared

    /// Au-delà, on ne déroule pas : l'historique complet vit dans `runs.jsonl`.
    private static let displayLimit = 30

    init(scheduleID: UUID, onOpen: @escaping (RunRecord) -> Void = { _ in }) {
        self.scheduleID = scheduleID
        self.onOpen = onOpen
    }

    private var records: [RunRecord] {
        Array(store.runs(of: scheduleID).prefix(Self.displayLimit))
    }

    var body: some View {
        // Pas de titre ni de compteur ici : l'onglet qui héberge cette vue s'appelle déjà
        // « Historique » et porte le nombre de runs.
        VStack(alignment: .leading, spacing: 8) {
            if records.isEmpty {
                Text("Aucune exécution enregistrée.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        RunHistoryRow(record: record, isSelected: record.id == store.selectedRunID)
                            .onTapGesture {
                                store.selectedRunID = record.id
                                onOpen(record)
                            }
                        if record.id != records.last?.id { Divider() }
                    }
                }
                .background(Color.secondary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct RunHistoryRow: View {
    let record: RunRecord
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunStatusPill(status: record.status, date: record.startedAt)
                .frame(width: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.message)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(Self.absolute(record.startedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let duration = record.duration {
                        Text("· \(Self.duration(duration))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    // Le déclencheur distingue un tir launchd d'un « Lancer maintenant ».
                    // C'est ce qui explique pourquoi un run n'a pas produit de bannière.
                    Text("· \(record.trigger)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .help("Voir la session de ce run.")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Ouvre la session de ce run")
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMM yyyy 'à' HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1f s", seconds)
            : String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }
}
