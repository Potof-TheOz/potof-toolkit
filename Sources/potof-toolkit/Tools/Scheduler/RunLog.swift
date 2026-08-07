import Foundation

/// Écriture et relecture de l'historique `runs.jsonl` — **lot L3**.
///
/// ## Le protocole d'écriture, à ne pas improviser
/// `open(O_WRONLY|O_CREAT|O_APPEND)` → `flock(LOCK_EX)` → **un seul** `write` →
/// `flock(LOCK_UN)` → `close`. C'est ce qui rend l'écriture sûre alors que **deux
/// process** écrivent dans ce fichier (la GUI et le runner headless).
///
/// Corollaire : `message` est plafonné à `RunLine.maxMessageLength`, et **jamais de corps
/// de log dans le JSONL** — le corps va dans `logs/<runID>.log`, référencé par `logPath`.
/// C'est ce qui garantit qu'une écriture reste un `write(2)` unique et court (< 4 Ko).
///
/// ## Compaction
/// Au lancement de la GUI **seulement**, si `runs.jsonl` > 2 Mo : `flock(LOCK_EX)`
/// bloquant, garder les 1 000 dernières lignes, réécriture **en place** + `ftruncate`.
/// ⚠️ **Surtout pas de `rename`** : ça changerait l'inode sous le nez d'un appender ayant
/// déjà son fd ouvert, dont les écritures partiraient dans un fichier fantôme.
final class RunLog {

    static let compactionThresholdBytes = 2 * 1024 * 1024
    static let compactionKeepLines = 1_000

    let runID: UUID
    let scheduleID: UUID
    let trigger: String

    init(runID: UUID, scheduleID: UUID, trigger: String) {
        self.runID = runID
        self.scheduleID = scheduleID
        self.trigger = trigger
    }

    // MARK: - Encodage

    /// **Jamais `.prettyPrinted`** : une ligne JSONL est une ligne. `.sortedKeys` rend
    /// l'écriture déterministe, ce qui aide quand on lit le fichier à la main.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Cycle de vie d'un run

    func start() {
        SchedulePaths.ensureDirectories()
        Self.append(RunLine.start(
            runID: runID,
            scheduleID: scheduleID,
            trigger: trigger,
            pid: ProcessInfo.processInfo.processIdentifier,
            at: Date()))
    }

    /// Ajoute une ligne au log **du run** (`logs/<runID>.log`), pas au JSONL. C'est ici
    /// que va tout ce qui est volumineux : sortie de `superset`, détail des garde-fous.
    func note(_ text: String) {
        SchedulePaths.ensureDirectories()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        let url = SchedulePaths.logFile(runID: runID)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var data = Data(line.utf8)
        _ = data.withUnsafeMutableBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }

    func finish(status: RunStatus, message: String,
                workspaceID: String?, worktreePath: String?) {
        let logURL = SchedulePaths.logFile(runID: runID)
        let logPath = FileManager.default.fileExists(atPath: logURL.path) ? logURL.path : nil
        Self.append(RunLine.end(
            runID: runID,
            scheduleID: scheduleID,
            at: Date(),
            status: status,
            message: message,
            workspaceID: workspaceID,
            worktreePath: worktreePath,
            logPath: logPath))
    }

    // MARK: - Écriture d'une ligne

    /// L'écriture entière est **un seul `write(2)`**, sous `flock` exclusif. Les deux
    /// `defer` se dépilent en ordre inverse : `LOCK_UN` puis `close`.
    static func append(_ line: RunLine) {
        guard var data = try? makeEncoder().encode(line) else { return }
        data.append(UInt8(ascii: "\n"))

        let url = SchedulePaths.runsFile
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        _ = data.withUnsafeMutableBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
    }

    // MARK: - Relecture

    /// Toutes les lignes décodables du JSONL. Une ligne illisible est **sautée**, jamais
    /// fatale : un fichier abîmé ne doit pas empêcher de voir l'historique restant.
    static func loadLines() -> [RunLine] {
        guard let data = try? Data(contentsOf: SchedulePaths.runsFile) else { return [] }
        let decoder = makeDecoder()
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(RunLine.self, from: Data($0)) }
    }

    /// Historique complet, plié et trié du plus récent au plus ancien.
    static func allRecords() -> [RunRecord] {
        RunRecord.fold(loadLines())
    }

    static func recent(scheduleID: UUID, limit: Int) -> [RunRecord] {
        Array(RunRecord.fold(loadLines().filter { $0.scheduleID == scheduleID }).prefix(limit))
    }

    // MARK: - Compaction

    /// Appelé par `AppDelegate` au démarrage, et **uniquement là** : compacter depuis le
    /// mode headless serait une réécriture concurrente d'un fichier qu'un autre process
    /// est peut-être en train d'appender.
    static func compactIfNeeded() {
        let url = SchedulePaths.runsFile
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > compactionThresholdBytes
        else { return }

        // O_RDWR et pas O_TRUNC : on réécrit **dans le même inode**. Un `rename` (ou une
        // écriture atomique, qui en fait un) ferait écrire un appender déjà ouvert dans
        // un fichier devenu invisible — ses runs disparaîtraient sans bruit.
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }   // bloquant : on attend l'appender
        defer { flock(fd, LOCK_UN) }

        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard lines.count > compactionKeepLines else { return }

        var out = Data()
        for line in lines.suffix(compactionKeepLines) {
            out.append(contentsOf: line)
            out.append(UInt8(ascii: "\n"))
        }

        lseek(fd, 0, SEEK_SET)
        let written = out.withUnsafeMutableBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        guard written > 0 else { return }
        // Tronquer APRÈS avoir écrit : si le process meurt entre les deux, le fichier
        // contient au pire les nouvelles lignes suivies d'un reliquat de l'ancien, dont
        // les lignes restent décodables une par une.
        ftruncate(fd, off_t(written))
    }
}
