import SwiftUI
import AppKit

/// Détail d'un package sélectionné : header (nom du manifest ou du dossier,
/// chemin `~`, badge du package manager détecté à la **racine du projet**) +
/// liste des scripts (nom, commande en monospace secondaire, bouton ▶ — ou
/// « voir le run » si un run actif existe déjà pour (package, script)).
///
/// Le `package.json` est **relu à chaud** à l'apparition (les scripts changent
/// souvent ; le parent pose `.id(package.id)` pour un état frais par package)
/// et au retour de l'app au premier plan (édition dans un éditeur externe,
/// pattern ClaudeLauncherView).
struct PackageDetailView: View {
    let package: ScriptPackage
    /// Racine du projet contenant le lockfile (== `package.dir` hors monorepo).
    let projectRoot: URL
    let projectName: String

    /// Store des runs (singleton app-level) : indicateurs « en cours » sur les
    /// lignes de scripts, lancement et focus.
    @ObservedObject private var runs = ScriptRunStore.shared
    /// Manifest relu à chaud — `nil` = package.json absent ou invalide.
    @State private var manifest: PackageManifest?
    /// Manager détecté par lockfile, re-détecté aux mêmes points de passage que
    /// le manifest (un lockfile peut apparaître/changer entre deux affichages).
    @State private var manager: PackageManager = .npm

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .onAppear(perform: reload)
        // package.json souvent édité hors de l'app → relecture au retour au
        // premier plan (même pattern que le rescan du Claude Launcher).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    /// Relit `package.json` et re-détecte le manager. **Le** point de passage
    /// de la relecture à chaud (onAppear + retour au premier plan).
    ///
    /// Lecture/parsing sur une file de fond : `Data(contentsOf:)` est synchrone
    /// et peut bloquer (fichier volumineux, ou « dataless » iCloud à retélécharger)
    /// — sur le main thread, ce serait un gel de l'UI à chaque retour au premier
    /// plan. Publication du résultat sur le main thread.
    private func reload() {
        let dir = package.dir
        let root = projectRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = PackageManifest.load(dir: dir)
            let detected = PackageManager.detect(packageDir: dir, projectRoot: root)
            DispatchQueue.main.async {
                manifest = loaded
                manager = detected
            }
        }
    }

    /// Révèle le `package.json` (pas le dossier) dans le Finder.
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [package.dir.appendingPathComponent("package.json")]
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.box.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    // Nom du manifest s'il existe, sinon le nom du dossier.
                    Text(manifest?.name ?? package.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if package.dir != projectRoot {
                        // Package imbriqué : rappel discret du projet parent.
                        Text("workspace de \(projectName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(package.displayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            managerBadge
            Button { revealInFinder() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Révéler le package.json dans le Finder")
            .accessibilityLabel("Révéler dans le Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .contextMenu {
            Button { revealInFinder() } label: {
                Label("Révéler dans le Finder", systemImage: "folder")
            }
        }
    }

    /// Capsule monospace discrète avec le manager détecté (npm/pnpm/yarn/bun).
    private var managerBadge: some View {
        Text(manager.rawValue)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("Gestionnaire détecté par lockfile à la racine du projet (\(rootDisplayPath))")
            .accessibilityLabel("Gestionnaire de paquets : \(manager.rawValue)")
    }

    private var rootDisplayPath: String {
        (projectRoot.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if let manifest {
            if manifest.scripts.isEmpty {
                emptyMessage(icon: "tray", text: "Aucun script dans ce package.json.")
            } else {
                scriptList(manifest.scripts)
            }
        } else {
            emptyMessage(icon: "exclamationmark.triangle", text: "package.json illisible.")
        }
    }

    private func scriptList(_ scripts: [PackageScript]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(scripts) { script in
                    ScriptRow(
                        script: script,
                        activeRun: runs.activeRun(packageDir: package.dir, script: script.name),
                        onPlay: {
                            runs.launch(
                                packageDir: package.dir,
                                projectRoot: projectRoot,
                                projectName: projectName,
                                script: script.name
                            )
                        },
                        onFocusRun: { runs.focus($0) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// État vide/erreur centré (pattern emptyMessage de GitStuffsView).
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

// MARK: - Ligne de script

/// Une ligne de la liste : nom + commande, et à droite soit ▶ (lancer), soit
/// pastille verte + « voir le run » quand un run est déjà actif pour ce script.
private struct ScriptRow: View {
    let script: PackageScript
    /// Run encore actif pour (package, script), s'il existe (dédup côté store).
    let activeRun: ScriptRun?
    let onPlay: () -> Void
    let onFocusRun: (UUID) -> Void
    @State private var hovering = false
    @State private var hoveringPlay = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(script.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Commande complète (souvent tronquée) au survol.
            .help(script.command)
            Spacer(minLength: 8)
            if let run = activeRun {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .help("Script en cours d'exécution")
                    .accessibilityLabel("En cours d'exécution")
                Button { onFocusRun(run.id) } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Voir le run en cours dans le terminal")
                .accessibilityLabel("Voir le run de « \(script.name) »")
            } else {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(hoveringPlay ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .onHover { hoveringPlay = $0 }
                .help("Lancer « \(script.name) »")
                .accessibilityLabel("Lancer le script \(script.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .onHover { hovering = $0 }
    }
}
