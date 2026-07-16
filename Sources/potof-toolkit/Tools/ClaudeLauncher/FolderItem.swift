import Foundation

/// Un sous-dossier affiché sous forme de carte.
struct FolderItem: Identifiable, Hashable {
    let name: String
    let url: URL
    /// Y a-t-il un `CLAUDE.md` à la racine du dossier ? Calculé une fois à la
    /// construction pour éviter un accès disque à chaque rendu de ligne. L'UI affiche
    /// alors la marque Claude.
    let hasClaudeMd: Bool
    /// Le dossier ressemble-t-il à un « vrai » projet (repo git, manifeste, README) ?
    /// Sert à ne proposer « Initialiser CLAUDE.md » que sur des cibles pertinentes,
    /// pas sur un dossier quelconque (ex. Téléchargements).
    let isProjectCandidate: Bool

    var id: URL { url }

    init(url: URL) {
        self.name = url.lastPathComponent
        self.url = url
        // **Un seul listing** du dossier alimente les deux drapeaux (inclut les fichiers
        // cachés comme `.git`) : évite un `fileExists` séparé pour `CLAUDE.md` EN PLUS du
        // listing de détection de projet.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let names = Set(entries)
        self.hasClaudeMd = names.contains("CLAUDE.md")
        self.isProjectCandidate = Self.detectProjectCandidate(entries: entries, names: names)
    }

    // MARK: - Détection de projet

    /// Fichiers/dossiers dont la présence à la racine trahit un projet, cherchés par
    /// **nom exact** dans le listing. `.git` couvre les repos ; les manifestes couvrent
    /// les stacks courantes ; le README couvre les projets encore sans manifeste.
    private static let projectManifestNames: Set<String> = [
        ".git",
        "package.json", "Cargo.toml", "Package.swift", "go.mod",
        "pyproject.toml", "requirements.txt", "setup.py", "Pipfile",
        "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
        "Gemfile", "composer.json", "CMakeLists.txt", "Makefile",
        "pubspec.yaml", "mix.exs", "Rakefile",
        "README.md", "README", "README.txt", "README.rst",
    ]

    /// Marqueurs « projet » à nom variable (Xcode, .NET) : nécessitent un listing,
    /// donc évalués en dernier recours seulement.
    private static let projectMarkerSuffixes: [String] = [
        ".xcodeproj", ".xcworkspace", ".sln", ".csproj",
    ]

    /// Décide à partir du **listing déjà obtenu** par `init` (aucun nouvel accès disque) :
    /// marqueur à nom exact (`names`) ou à suffixe (`entries`). L'ancienne version faisait
    /// ~27 `fileExists` par dossier, ce qui pesait sur le scan multiplié par leur nombre.
    private static func detectProjectCandidate(entries: [String], names: Set<String>) -> Bool {
        if !names.isDisjoint(with: projectManifestNames) { return true }
        return entries.contains { entry in
            projectMarkerSuffixes.contains { entry.hasSuffix($0) }
        }
    }
}
