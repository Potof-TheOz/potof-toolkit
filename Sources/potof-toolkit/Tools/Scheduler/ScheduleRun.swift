import Foundation

/// Issue d'un run.
///
/// ⭐ `launched` et **pas** `ok` : le runner ne sait rien du résultat de l'agent, il sait
/// seulement que `superset agents create` a rendu 0. L'UI dit « agent lancé à 10:00 »,
/// jamais « réussi ». Un historique tout vert ne doit pas se lire comme une garantie de
/// livrable — la vérification du livrable est **hors périmètre** et reste côté métier.
///
/// `skipped` **n'est pas un échec** : c'est un garde-fou qui a joué (agent encore vif,
/// run déjà en cours, planification désactivée). L'UI les distingue — orange contre
/// rouge — sans quoi on crie au loup tous les jours et on finit par ne plus regarder.
enum RunStatus: String, Codable, Hashable {
    case launched, failed, skipped, running, interrupted

    /// Un run qui mérite une bannière système (§6.7). `launched` n'en mérite pas.
    var deservesNotification: Bool {
        self == .failed || self == .skipped
    }
}

/// Une **ligne** du JSONL. Deux par run : `start` puis `end`.
///
/// Pourquoi deux lignes plutôt qu'une écrite à la fin : une ligne est **toujours
/// complète** quand elle est écrite ; un run en cours est visible immédiatement ; un run
/// interrompu (crash, reboot) se lit tout seul — `start` sans `end` et pid mort.
struct RunLine: Codable, Hashable {
    enum Phase: String, Codable, Hashable { case start, end }

    var v: Int = 1
    let runID: UUID
    let scheduleID: UUID
    let phase: Phase
    let at: Date

    // Renseignés sur `start` seulement.
    var trigger: String?
    var pid: Int32?

    // Renseignés sur `end` seulement.
    var status: RunStatus?
    var workspaceID: String?
    var worktreePath: String?
    var message: String?
    var logPath: String?

    /// Plafond du champ `message`. Jamais de corps de log dans le JSONL : le corps va
    /// dans `logs/<runID>.log`. C'est ce qui garantit qu'une écriture reste un `write(2)`
    /// unique et court (< 4 Ko), donc atomique en pratique sous `flock`.
    static let maxMessageLength = 500

    static func start(runID: UUID, scheduleID: UUID, trigger: String, pid: Int32, at: Date) -> RunLine {
        RunLine(runID: runID, scheduleID: scheduleID, phase: .start, at: at,
                trigger: trigger, pid: pid)
    }

    static func end(
        runID: UUID, scheduleID: UUID, at: Date, status: RunStatus, message: String,
        workspaceID: String?, worktreePath: String?, logPath: String?
    ) -> RunLine {
        RunLine(runID: runID, scheduleID: scheduleID, phase: .end, at: at,
                status: status,
                workspaceID: workspaceID,
                worktreePath: worktreePath,
                message: String(message.prefix(maxMessageLength)),
                logPath: logPath)
    }
}

/// Projection **affichable** d'un run, reconstruite depuis les lignes du JSONL.
struct RunRecord: Identifiable, Hashable {
    /// = `runID`.
    let id: UUID
    let scheduleID: UUID
    let trigger: String
    let startedAt: Date
    let endedAt: Date?
    let status: RunStatus
    let message: String
    let workspaceID: String?
    let worktreePath: String?
    let logPath: String?

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

extension RunRecord {

    /// Plie les lignes en enregistrements, **du plus récent au plus ancien**.
    ///
    /// Un `start` sans `end` est soit un run réellement en cours (`running`), soit un run
    /// mort en route (`interrupted`) — la seule chose qui départage est l'existence du
    /// pid. Aucun état à réconcilier sur disque, aucun nettoyage : le JSONL reste
    /// append-only et se relit toujours de la même façon.
    static func fold(_ lines: [RunLine]) -> [RunRecord] {
        fold(lines, isAlive: processExists)
    }

    /// Variante injectable — `fold(_:)` est la signature du contrat, celle-ci existe pour
    /// que le pliage reste vérifiable sans dépendre des pids réels de la machine.
    static func fold(_ lines: [RunLine], isAlive: (Int32) -> Bool) -> [RunRecord] {
        var starts: [UUID: RunLine] = [:]
        var ends: [UUID: RunLine] = [:]
        var order: [UUID] = []

        for line in lines {
            switch line.phase {
            case .start:
                if starts[line.runID] == nil { order.append(line.runID) }
                starts[line.runID] = line
            case .end:
                // Un `end` orphelin (JSONL compacté au milieu d'un run) reste exploitable :
                // il crée l'entrée, la date de début vaudra celle de fin.
                if starts[line.runID] == nil && ends[line.runID] == nil { order.append(line.runID) }
                ends[line.runID] = line
            }
        }

        let records: [RunRecord] = order.compactMap { runID in
            let start = starts[runID]
            let end = ends[runID]
            guard let anchor = start ?? end else { return nil }

            let status: RunStatus
            if let end, let endStatus = end.status {
                status = endStatus
            } else if let pid = start?.pid, isAlive(pid) {
                status = .running
            } else {
                status = .interrupted
            }

            return RunRecord(
                id: runID,
                scheduleID: anchor.scheduleID,
                trigger: start?.trigger ?? "?",
                startedAt: start?.at ?? anchor.at,
                endedAt: end?.at,
                status: status,
                message: end?.message ?? (status == .running ? "en cours…" : "run interrompu"),
                workspaceID: end?.workspaceID,
                worktreePath: end?.worktreePath,
                logPath: end?.logPath
            )
        }

        return records.sorted { $0.startedAt > $1.startedAt }
    }

    /// `kill(pid, 0)` : ne signale rien, teste seulement l'existence du process. `EPERM`
    /// compte comme vivant (process d'un autre utilisateur — impossible ici, mais on ne
    /// veut surtout pas déclarer « interrompu » un run qui tourne).
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
