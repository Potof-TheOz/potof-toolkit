import SwiftUI
import AppKit

/// Outil « Claude Launcher » : liste les sous-dossiers d'un dossier racine et
/// lance `claude` dans iTerm2 au clic sur une carte. Les dossiers peuvent être
/// ajoutés aux favoris, mis en avant en tête de liste.
struct ClaudeLauncherView: View {
    @AppStorage("rootPath") private var rootPath: String = ""
    @StateObject private var favorites = FavoritesStore()
    @State private var subfolders: [FolderItem] = []
    @State private var searchText: String = ""

    // MARK: - Données dérivées

    /// Favoris existants sur le disque (indépendants du dossier racine).
    private var favoriteItems: [FolderItem] {
        favorites.paths
            .compactMap { path -> FolderItem? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return FolderItem(name: (path as NSString).lastPathComponent,
                                  url: URL(fileURLWithPath: path))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func filter(_ items: [FolderItem]) -> [FolderItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredFavorites: [FolderItem] { filter(favoriteItems) }
    private var filteredAll: [FolderItem] { filter(subfolders) }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(rootPath: rootPath, onChange: chooseFolder, onRefresh: scan)
            Divider()
            Group {
                if rootPath.isEmpty {
                    EmptyStateView(onChoose: chooseFolder)
                } else {
                    folderBrowser
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear(perform: scan)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scan()
        }
    }

    // MARK: - Sous-vues

    private var folderBrowser: some View {
        VStack(spacing: 0) {
            searchBar
            if subfolders.isEmpty && favoriteItems.isEmpty {
                messageView(
                    icon: "tray",
                    title: "Aucun sous-dossier",
                    subtitle: "Ce dossier racine ne contient aucun sous-dossier visible."
                )
            } else if filteredAll.isEmpty && filteredFavorites.isEmpty {
                messageView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    subtitle: "Aucun dossier ne correspond à « \(searchText) »."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !filteredFavorites.isEmpty {
                            folderSection(
                                title: "Favoris",
                                systemImage: "star.fill",
                                tint: .yellow,
                                items: filteredFavorites
                            )
                        }
                        if !filteredAll.isEmpty {
                            folderSection(
                                title: favoriteItems.isEmpty ? nil : "Tous les dossiers",
                                systemImage: nil,
                                tint: .secondary,
                                items: filteredAll
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Rechercher un dossier", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .frame(maxWidth: 340, alignment: .leading)

            Spacer(minLength: 0)

            Text("\(filteredAll.count) dossier\(filteredAll.count > 1 ? "s" : "")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func folderSection(title: String?, systemImage: String?, tint: Color, items: [FolderItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.headline)
                    Text("\(items.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16)],
                spacing: 16
            ) {
                ForEach(items) { item in
                    FolderCard(
                        item: item,
                        isFavorite: favorites.isFavorite(item.url.path),
                        onOpen: { ITermLauncher.launch(at: item.url.path) },
                        onToggleFavorite: { favorites.toggle(item.url.path) }
                    )
                }
            }
        }
    }

    private func messageView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func scan() {
        guard !rootPath.isEmpty else {
            subfolders = []
            return
        }
        let rootURL = URL(fileURLWithPath: rootPath)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            subfolders = []
            return
        }
        subfolders = contents
            .filter { url in
                // Dossiers uniquement, jamais rien commençant par "." (double garde).
                guard !url.lastPathComponent.hasPrefix(".") else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true
            }
            .map { FolderItem(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choisissez le dossier racine"
        panel.prompt = "Choisir"
        if !rootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: rootPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
            searchText = ""
            scan()
        }
    }
}

// MARK: - Barre supérieure

private struct TopBar: View {
    let rootPath: String
    let onChange: () -> Void
    let onRefresh: () -> Void

    private var displayPath: String {
        (rootPath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("Dossier racine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(rootPath.isEmpty ? "Aucun dossier sélectionné" : displayPath)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rootPath)
            }

            Spacer(minLength: 12)

            Button(action: onRefresh) {
                Label("Rafraîchir", systemImage: "arrow.clockwise")
            }
            .disabled(rootPath.isEmpty)
            .keyboardShortcut("r", modifiers: .command)

            Button(action: onChange) {
                Label("Changer de dossier", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - État vide (aucun dossier racine)

private struct EmptyStateView: View {
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Choisissez un dossier pour commencer")
                .font(.title3.weight(.semibold))
            Text("Sélectionnez un dossier racine : ses sous-dossiers apparaîtront ici sous forme de cartes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onChoose) {
                Label("Choisir un dossier", systemImage: "folder")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Carte de dossier

private struct FolderCard: View {
    let item: FolderItem
    let isFavorite: Bool
    let onOpen: () -> Void
    let onToggleFavorite: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(hovering: hovering))
        .overlay(alignment: .topTrailing) {
            if hovering || isFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris")
            }
        }
        .onHover { hovering = $0 }
        .help(item.url.path)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity: Double = configuration.isPressed ? 0.16 : (hovering ? 0.09 : 0.035)
        let strokeOpacity: Double = hovering ? 0.14 : 0.06

        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
