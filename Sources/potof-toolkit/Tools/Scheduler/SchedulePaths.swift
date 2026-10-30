import Foundation

/// Tous les chemins du Claude Scheduler, en un seul endroit.
///
/// Même construction inline que `ConventionsProfile` / `NotificationChannel` / `IDELog` :
/// **pas de helper partagé**, on reste sur le pattern déjà en place dans le repo.
///
/// Pourquoi des fichiers et pas `UserDefaults` : (1) aucune notification de changement
/// inter-process — la GUI ne verrait jamais qu'un run headless vient de finir ;
/// (2) lecture-modification-écriture non atomique sur un tableau ⇒ perte silencieuse ;
/// (3) non inspectable, non diffable ; (4) en `swift run` le domaine diverge
/// (`potof-toolkit` vs `com.potof.potof-toolkit`).
enum SchedulePaths {

    // MARK: - Racine (et son détournement pour les probes)

    /// Racine de travail. `nil` = emplacement réel. Renseignée **UNIQUEMENT** par les
    /// probes d'auto-test, pour opérer dans un dossier jetable.
    ///
    /// ⚠️ À ne pas confondre avec le `--dry-run` du runner, qui ne la touche **pas** : s'il
    /// n'écrit rien, c'est parce que son `Reporter` n'a pas de `RunLog`, qu'il ne pose
    /// aucun verrou et qu'il n'installe aucun job — pas parce que ses chemins seraient
    /// détournés. Un `--dry-run` lit et imprime les vrais chemins, et c'est voulu.
    ///
    /// ⚠️ C'est ce qui rend L2 et L3 vérifiables **sans effet de bord** : quand
    /// `isDryRun` est vrai, `install`/`remove` doivent court-circuiter
    /// `launchctl`, et rien ne doit atterrir dans le vrai `~/Library/LaunchAgents`.
    static var overrideRoot: URL?

    static var isDryRun: Bool { overrideRoot != nil }

    /// `~/Library/Application Support/PotofToolkit/scheduler/`
    static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PotofToolkit", isDirectory: true)
            .appendingPathComponent("scheduler", isDirectory: true)
    }

    /// Source de vérité. Écrite **UNIQUEMENT par la GUI**, atomiquement.
    static var schedulesFile: URL { root.appendingPathComponent("schedules.json", isDirectory: false) }

    /// Historique append-only. Écrit par la GUI **et** par le headless.
    static var runsFile: URL { root.appendingPathComponent("runs.jsonl", isDirectory: false) }

    static var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var locksDirectory: URL { root.appendingPathComponent("locks", isDirectory: true) }

    static func logFile(runID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(runID.uuidString).log", isDirectory: false)
    }

    /// Flux brut du pseudo-terminal du run (préscript puis session `claude`), rejoué
    /// tel quel par la GUI.
    static func ttyFile(runID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(runID.uuidString).tty", isDirectory: false)
    }

    /// Posé par le hook `Stop` injecté dans les settings du run : « la réponse est finie ».
    static func stopMarker(runID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(runID.uuidString).stop", isDirectory: false)
    }

    /// Settings passés à `claude --settings` : ceux de la planification + le hook `Stop`.
    static func runSettingsFile(runID: UUID) -> URL {
        logsDirectory.appendingPathComponent("\(runID.uuidString).settings.json", isDirectory: false)
    }

    /// Verrou **par dossier**, pas par planification : deux planifications qui visent le même
    /// dossier ne doivent jamais lancer deux sessions sur la même copie de travail. Nom =
    /// FNV-1a 64 bits du chemin normalisé (liens résolus, sans `/` final) : stable d'un
    /// process à l'autre, contrairement à `hashValue`, et sans `CryptoKit` (mode headless en
    /// `Foundation` seul).
    static func lockFile(folderPath: String) -> URL {
        let normalized = URL(fileURLWithPath: folderPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return locksDirectory.appendingPathComponent("folder-\(String(hash, radix: 16)).lock",
                                                     isDirectory: false)
    }

    // MARK: - launchd

    /// `~/Library/LaunchAgents`, ou une doublure jetable sous `overrideRoot`.
    static var launchAgentsDirectory: URL {
        if let overrideRoot { return overrideRoot.appendingPathComponent("LaunchAgents", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static func launchAgentPlistURL(for schedule: Schedule) -> URL {
        launchAgentsDirectory
            .appendingPathComponent("\(schedule.launchAgentLabel).plist", isDirectory: false)
    }

    /// `StandardOutPath` du plist. ⚠️ Ce dossier doit exister **avant** le `bootstrap`,
    /// sinon le job échoue à se lancer sans message exploitable.
    static func launchdLogFile(scheduleID: UUID) -> URL {
        launchdLogsDirectory
            .appendingPathComponent("schedule-\(scheduleID.uuidString.lowercased()).out.log",
                                    isDirectory: false)
    }

    static var launchdLogsDirectory: URL {
        if let overrideRoot { return overrideRoot.appendingPathComponent("Logs", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/PotofToolkit", isDirectory: true)
    }

    // MARK: - Exécutables

    /// Le binaire que launchd exécutera. En app bundlée :
    /// `…/Potof Toolkit.app/Contents/MacOS/potof-toolkit`.
    static var hostExecutableURL: URL {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/bin/false")
    }

    /// **Même garde que `canUseUN`** (`NotificationCenterCoordinator`, `DiffReviewWindow`) :
    /// en `swift run` le binaire est dans `.build/debug/`, chemin éphémère effacé par
    /// `swift package clean`. Un plist pointant là serait mort au premier nettoyage, sans
    /// le moindre signal. On refuse donc d'installer, et l'UI le dit.
    static var canInstallLaunchAgents: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// PATH recopié dans le plist. Le PATH par défaut sous launchd est
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. Le runner passe de toute façon par un shell de
    /// login interactif (`$SHELL -l -i`), qui recharge le PATH des rc ; celui-ci n'est que
    /// le plancher, avec `~/.local/bin` où l'installeur natif pose `claude`. Chemins
    /// littéraux — launchd ne développe pas `$HOME`.
    static var searchPath: String {
        [
            NSHomeDirectory() + "/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ].joined(separator: ":")
    }

    // MARK: - Création

    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for directory in [root, logsDirectory, locksDirectory, launchdLogsDirectory] {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return true
    }
}
