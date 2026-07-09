import SwiftUI

/// Emplacement de notif dans le header — **ancrage (Phase 4)**.
///
/// Cloche + popover listant les événements du `NotificationBus`. Tant que le
/// canal n'est pas branché, la liste reste vide (« Aucune notification »). La
/// cloche est volontairement toujours présente pour réserver la place et valider
/// la mécanique d'affichage.
struct NotificationSlot: View {
    @ObservedObject var bus: NotificationBus
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: bus.count > 0 ? "bell.badge.fill" : "bell")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(bus.count > 0 ? Color.accentColor : .secondary)
                .overlay(alignment: .topTrailing) {
                    if bus.count > 0 {
                        Text("\(bus.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .offset(x: 8, y: -8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bus.count > 0 ? "Afficher les notifications (\(bus.count))" : "Notifications (aucune)")
        .accessibilityLabel(bus.count > 0 ? "Notifications, \(bus.count) non lues" : "Notifications, aucune")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 320)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                if bus.count > 0 {
                    Button("Tout effacer") { bus.clear() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            if bus.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Aucune notification")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(bus.items) { note in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: note.symbol)
                                    .foregroundStyle(note.kind == .finished ? .green : .orange)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.system(size: 12, weight: .semibold))
                                    Text(note.body).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }
}
