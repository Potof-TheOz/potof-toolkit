import SwiftUI
import AppKit

/// **Panneau de diagnostic de l'hôte IDE** — lecture seule.
///
/// Son unique raison d'être : répondre à « est-ce que ça marche ? ». Quand un agent
/// Superset n'ouvre pas de fenêtre de revue, la question est toujours la même — est-ce
/// que l'hôte tourne, sur quel périmètre, et cet agent est-il seulement connecté ? Trois
/// informations, affichées telles quelles.
///
/// Ce n'est **pas** un centre de configuration : le seul réglage qui change quelque chose
/// (le périmètre) vit dans le menu « Hôte IDE », d'où on ouvre cette fenêtre. On se
/// contente ici de refléter l'état.
struct IDEHostStatusView: View {

    // Singletons app-level observés (invariant du projet : l'état adossé à des process
    // ou des sockets ne vit jamais dans un `@StateObject` de vue).
    @ObservedObject private var host = IDEHost.shared
    @ObservedObject private var settings = IDEHostSettings.shared

    /// Horloge de rafraîchissement des « connecté depuis » : sans elle, les durées
    /// figeraient jusqu'à la prochaine mutation de `clients`.
    @State private var now = Date()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scopeSection
                    settingsSection
                    clientsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 380)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(host.port != nil ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.port != nil ? "Hôte IDE actif" : "Hôte IDE inactif")
                    .font(.headline)
                Text(host.port.map { "127.0.0.1:\($0) — les agents `claude` du périmètre s'y connectent seuls"
                        } ?? "Aucun lock publié : les agents utilisent le prompt de permission de leur terminal")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Périmètre

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Périmètre servi")
            Text(settings.scope.title).font(.body)
            Text(settings.scope.detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(settings.scope.servedFolders, id: \.path) { folder in
                Text(folder.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Text("Modifiable dans le menu « Hôte IDE ».")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Réglages (reflet, pas d'édition)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Réglages")
            keyValue("Activer l'app à la réception",
                     settings.activateAppOnRequest ? "oui" : "non")
            keyValue("Expiration d'une demande", settings.requestTimeoutLabel)
            // Le pourquoi, affiché : sans ça, « aucune » passe pour un oubli.
            Text("Sans expiration, un agent attend indéfiniment une décision : c'est "
                 + "délibéré — expirer reviendrait à refuser la modification dans le dos "
                 + "de l'utilisateur.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Clients

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Clients connectés (\(host.clients.count))")
            if host.clients.isEmpty {
                Text(host.port != nil
                     ? "Aucun agent connecté. `claude` ne tente l'auto-connexion que pendant "
                       + "ses 30 premières secondes : un agent démarré avant l'app ne se "
                       + "connectera pas tout seul (remède : /ide)."
                     : "L'hôte est arrêté.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(host.clients) { client in
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: IDEHostClient) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(client.identity.label).font(.body).lineLimit(1)
                if client.identity.isSuperset {
                    Text("Superset")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
                Text("connecté depuis \(Self.age(from: client.connectedAt, to: now))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(client.identity.cwd?.path ?? "répertoire de travail inconnu")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)      // la fin du chemin est la partie informative
                .textSelection(.enabled)
                .help(client.identity.cwd?.path ?? "Le pid du client n'a pas permis de résoudre son cwd")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pied

    private var footer: some View {
        HStack(spacing: 8) {
            Text(host.port.map { "~/.claude/ide/\($0).lock" } ?? "aucun lock")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button {
                // Révèle plutôt qu'ouvrir : `ide.log` grossit vite et l'utilisateur a
                // souvent un `tail -f` dessus, pas besoin de lui imposer un éditeur.
                NSWorkspace.shared.activateFileViewerSelecting([IDELog.fileURL])
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Révéler le journal du pont IDE dans le Finder (ide.log)")
            .accessibilityLabel("Révéler le journal du pont IDE")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Briques

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
        .font(.body)
    }

    /// Durée compacte « 12 s » / « 3 min » / « 2 h 05 ». Pas de
    /// `RelativeDateTimeFormatter` : on veut une **durée**, pas un « il y a … », et le
    /// libellé porte déjà « connecté depuis ».
    static func age(from date: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d", s / 3600, (s % 3600) / 60)
    }
}
