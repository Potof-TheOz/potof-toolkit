import Foundation
import Combine

/// Source de vérité des planifications — **lot L3**.
///
/// ## L'invariant qui supprime toute une classe de bugs
/// **`schedules.json` a un seul écrivain : la GUI.** Le mode headless est **lecteur
/// seul**, et unique écrivain de sa portion du JSONL. C'est pour ça qu'il n'y a pas de
/// `lastRunAt` dans `Schedule` : il est **dérivé** de `runs.jsonl`. Sans cet invariant il
/// faudrait arbitrer des courses lecture-modification-écriture entre deux process.
///
/// ## Process-backed ⇒ singleton app-level
/// `RootView` pose `.id(tool.id)` sur la vue de l'outil : changer d'outil **détruit** la
/// vue et ses `@StateObject`. Tout état adossé à des process ou à des fichiers surveillés
/// vit donc dans un singleton, observé via `@ObservedObject`. Ne PAS revenir à un
/// `@StateObject` ici.
///
/// Le tail de `runs.jsonl` suit le pattern `NotificationChannel` (`DispatchSource` vnode)
/// **mais SANS le `O_TRUNC` de son `start()`** — l'historique, lui, doit survivre au
/// lancement de l'app. C'est ce qui fait apparaître un run headless dans l'UI en direct.
///
/// ⚠️ Toutes les méthodes publiques sont à appeler **sur le thread principal** (elles
/// mutent des `@Published`) — mais aucune n'y fait de travail lent : `runNow` part en fond
/// et republie, et `upsert`/`setEnabled`/`remove` renvoient leur mutation launchd sur une
/// file sérielle (cf. `applyLaunchAgent`). Elles rendent donc la main tout de suite, et
/// l'état launchd converge après coup.
final class ScheduleStore: ObservableObject {

    static let shared = ScheduleStore()
    private init() {}

    @Published private(set) var schedules: [Schedule] = []
    @Published private(set) var runs: [RunRecord] = []
    @Published var selection: UUID?
    @Published private(set) var lastError: String?

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchHandle: FileHandle?
    private var reopening = false

    /// File **sérielle** dédiée aux mutations launchd. Sérielle et pas concurrente : deux
    /// séquences `bootout`/`enable`/`bootstrap` entrelacées sur le même label — un
    /// double clic sur l'interrupteur — laisseraient un job dans un état qui ne
    /// correspond ni à l'avant ni à l'après.
    private let launchAgentQueue = DispatchQueue(label: "com.potof.toolkit.scheduler.launchd")

    // MARK: - Format sur disque (SOCLE — gelé, ne pas modifier sans escalade)

    /// Enveloppe versionnée de `schedules.json`.
    struct SchedulesFile: Codable {
        var version: Int
        var schedules: [Schedule]

        static let currentVersion = 1
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// **Implémentée par le socle** (et non par L3) parce que le mode headless en dépend :
    /// sans elle, `--run-schedule` ne saurait pas dire « planification introuvable ».
    ///
    /// Renvoie un tableau vide si le fichier est absent (cas nominal au premier
    /// lancement) ou illisible — un runner ne doit jamais crasher sur un fichier abîmé,
    /// il doit sortir proprement en 66.
    static func loadFromDisk() -> [Schedule] {
        guard let data = try? Data(contentsOf: SchedulePaths.schedulesFile) else { return [] }
        guard let file = try? makeDecoder().decode(SchedulesFile.self, from: data) else { return [] }
        return file.schedules
    }

    // MARK: - Lecture

    func reload() {
        schedules = Self.sorted(Self.loadFromDisk())
        reloadRuns()
        startWatchingRuns()

        // Sans ça, tout démarrage tombe sur « Sélectionnez une planification » : pas de
        // détail, donc pas d'historique — et on croit l'avoir perdu. On sélectionne aussi
        // quand la sélection courante désigne une planification qui n'existe plus
        // (supprimée, ou fichier réécrit hors de l'app).
        if selection == nil || !schedules.contains(where: { $0.id == selection }) {
            selection = schedules.first?.id
        }
    }

    /// Recharge **seulement** l'historique. Appelée par le tail à chaque écriture.
    func reloadRuns() {
        runs = RunLog.allRecords()
    }

    /// Dernier run d'une planification, quel qu'en soit le statut. C'est la seule source
    /// de « quand a-t-elle tourné pour la dernière fois » — il n'y a délibérément pas de
    /// `lastRunAt` dans `Schedule`.
    func lastRun(of scheduleID: UUID) -> RunRecord? {
        runs.first { $0.scheduleID == scheduleID }
    }

    func runs(of scheduleID: UUID) -> [RunRecord] {
        runs.filter { $0.scheduleID == scheduleID }
    }

    private static func sorted(_ schedules: [Schedule]) -> [Schedule] {
        schedules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Écriture

    /// Écriture **atomique** puis (ré)synchronisation du job launchd.
    func upsert(_ schedule: Schedule) {
        var updated = schedule
        updated.updatedAt = Date()

        if let index = schedules.firstIndex(where: { $0.id == updated.id }) {
            schedules[index] = updated
        } else {
            schedules.append(updated)
        }
        schedules = Self.sorted(schedules)

        guard save() else { return }
        syncLaunchAgent(for: updated)
    }

    func remove(id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        let removed = schedules.remove(at: index)

        guard save() else { return }
        // Le plist part même si la planification était désactivée : un plist sans
        // `Schedule` correspondant est précisément ce que `audit()` remonte en orphelin.
        guard SchedulePaths.canInstallLaunchAgents || SchedulePaths.isDryRun else { return }
        applyLaunchAgent { SchedulerService.shared.remove(removed) }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].enabled = enabled
        schedules[index].updatedAt = Date()

        guard save() else { return }
        syncLaunchAgent(for: schedules[index])
    }

    /// `false` si l'écriture a échoué — l'appelant s'arrête alors **avant** de toucher à
    /// launchd : un job installé pour une planification qu'on n'a pas su écrire serait
    /// un orphelin immédiat.
    @discardableResult
    private func save() -> Bool {
        SchedulePaths.ensureDirectories()
        let file = SchedulesFile(version: SchedulesFile.currentVersion, schedules: schedules)
        do {
            let data = try Self.makeEncoder().encode(file)
            try data.write(to: SchedulePaths.schedulesFile, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Impossible d'écrire schedules.json : \(error.localizedDescription)"
            return false
        }
    }

    /// Activée ⇒ installer, désactivée ⇒ retirer. En dev (`swift run`), on ne touche
    /// **jamais** à launchd : le binaire vit dans `.build/debug/`, chemin éphémère.
    private func syncLaunchAgent(for schedule: Schedule) {
        guard SchedulePaths.canInstallLaunchAgents || SchedulePaths.isDryRun else { return }
        applyLaunchAgent {
            schedule.enabled
                ? SchedulerService.shared.install(schedule)
                : SchedulerService.shared.remove(schedule)
        }
    }

    /// Exécute une mutation launchd **hors du thread principal** et republie l'erreur
    /// éventuelle dessus. `install` enchaîne trois `launchctl` synchrones (`bootout`,
    /// `enable`, `bootstrap`) et `bootstrap` peut traîner : le faire depuis l'interrupteur
    /// de la sidebar gelait l'interface. Même règle que `SchedulerView.testTrigger`.
    ///
    /// ⚠️ **Exception dry-run : l'appel reste synchrone.** Les probes tournent en CLI, sans
    /// runloop, et vérifient l'état du dossier jetable juste après l'appel — une file de
    /// fond n'aurait rien fait à ce moment-là.
    private func applyLaunchAgent(_ work: @escaping () -> LaunchAgentResult) {
        guard !SchedulePaths.isDryRun else {
            let result = work()
            if !result.ok { lastError = result.message }
            return
        }
        launchAgentQueue.async {
            let result = work()
            guard !result.ok else { return }
            DispatchQueue.main.async { [weak self] in self?.lastError = result.message }
        }
    }

    // MARK: - Lancer maintenant

    /// **Le même** `ScheduleRunner.execute` que le mode headless, sur une file de fond,
    /// avec `trigger: "manual"`. Retour live dans l'UI via le tail ; fonctionne en
    /// `swift run` ; et le `flock` étant **inter-process**, un tir launchd concurrent est
    /// correctement exclu. C'est le **seul** chemin de l'UI qui lance un run réel — voir
    /// `SchedulerService`, où l'ancien `launchctl kickstart` a été retiré pour cette raison.
    func runNow(id: UUID) {
        guard let schedule = schedules.first(where: { $0.id == id }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = ScheduleRunner.execute(schedule, trigger: "manual", dryRun: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reloadRuns()
                if status == .failed {
                    self.lastError = "« \(schedule.name) » : le lancement a échoué "
                        + "(voir l'historique)."
                }
            }
        }
    }

    // MARK: - Tail de runs.jsonl

    /// Surveille le JSONL et republie l'historique à chaque écriture — y compris celles
    /// d'un **autre process** (le runner headless de launchd). C'est ce qui rend
    /// l'historique vivant sans polling.
    func startWatchingRuns() {
        guard watchSource == nil else { return }
        SchedulePaths.ensureDirectories()

        let url = SchedulePaths.runsFile
        // Créer sans tronquer : contrairement à `NotificationChannel.start()`, on ne
        // repart PAS de zéro — l'historique doit survivre au lancement de l'app.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        watchHandle = handle

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.watchSource?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopenWatch()
            } else {
                self.reloadRuns()
            }
        }
        source.setCancelHandler { [weak handle] in
            try? handle?.close()
        }
        watchSource = source
        source.resume()
    }

    func stopWatchingRuns() {
        watchSource?.cancel()          // le cancelHandler ferme le handle
        watchSource = nil
        watchHandle = nil
    }

    /// Fichier supprimé/renommé (le fd pointe l'ancien inode) : on ré-arme sur le nouveau.
    /// Léger debounce, même raison que `NotificationChannel.reopen()`.
    private func reopenWatch() {
        guard !reopening else { return }
        reopening = true
        stopWatchingRuns()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.reopening = false
            self.startWatchingRuns()
            self.reloadRuns()
        }
    }

    // MARK: - Auto-test

    static func probe() -> String {
        ScheduleStoreProbe.run()
    }
}
