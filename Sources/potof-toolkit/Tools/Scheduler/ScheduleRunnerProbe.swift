import Foundation

/// Auto-test du runner — `potof-toolkit --sched-selftest run` (et `live`, opt-in).
///
/// `run` opère dans un dossier jetable (`SchedulePaths.overrideRoot`) avec un **faux
/// `claude`** (script sh écrit dans ce dossier) : aucun vrai `claude`, aucun réseau, aucune
/// bannière. Il déroule la séquence complète du runner — préscript, contrôle des MCP,
/// settings du run, session dans un PTY — et vérifie chaque issue du tableau de séquence
/// au mot près, plus les garde-fous transverses (verrou, politique de notification,
/// dry-run sans trace).
///
/// `live <dossier approuvé>` lance le VRAI `claude` (haiku, environ 0,01 $) : c'est la
/// seule preuve que le hook `Stop`, `/exit` et le retrait de `CLAUDE_CODE_*` tiennent
/// face au binaire réel.
enum ScheduleRunnerProbe {

    /// Extrait réel de `claude mcp list` (2026-10-30), couleurs ANSI comprises — le même
    /// que celui de la probe `claude`.
    private static let mcpSample = "Checking MCP server health…\r\n\r\n"
        + "claude.ai Asana: https://mcp.asana.com/sse - ! Needs authentication\r\n"
        + "plugin:sentry-mcp:sentry: https://mcp.sentry.dev/mcp (HTTP) - \u{1B}[32m✔ Connected\u{1B}[39m\r\n"
        + "webstorm: http://127.0.0.1:64342/sse (SSE) - ✘ Failed to connect — SSE error: ECONNREFUSED\r\n"
        + "n8n-prod: /Users/x/.nvm/versions/node/v26.5.0/bin/n8n-mcp  - ✔ Connected\r\n"

    static func run() -> String {
        var out: [String] = []
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                out.append("  [OK  ] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                failures += 1
                out.append("  [ÉCHEC] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-sched-runner-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = nil }

        // Le faux `claude` vit hors du dossier de la planification : ses fichiers de
        // contrôle (`argv.txt`, `FAKE_MODE`, `mcp.txt`) ne se mélangent pas au travail.
        let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
        let folder = root.appendingPathComponent("dossier projet", isDirectory: true)
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let argvFile = sandbox.appendingPathComponent("argv.txt")
        let modeFile = sandbox.appendingPathComponent("FAKE_MODE")
        let mcpFile = sandbox.appendingPathComponent("mcp.txt")
        let fakeClaude = sandbox.appendingPathComponent("claude")
        try? Data(mcpSample.utf8).write(to: mcpFile)

        let q = ClaudeInvocation.shellQuote
        let script = """
        #!/bin/sh
        if [ "$1" = mcp ] && [ "$2" = list ]; then
          cat \(q(mcpFile.path))
          exit 0
        fi
        for a in "$@"; do printf '%s\\n' "$a"; done > \(q(argvFile.path))
        echo FAKE-CLAUDE
        settings=""; prev=""
        for a in "$@"; do [ "$prev" = --settings ] && settings="$a"; prev="$a"; done
        case "$(cat \(q(modeFile.path)) 2>/dev/null)" in
          ok)
            eval "$(grep -o "touch '[^']*'" "$settings" | sed 's#\\\\/#/#g')"
            read l; [ "$l" = /exit ] && exit 0; exit 9 ;;
          crash) exit 1 ;;
          trust) printf 'Do you\\033[1Ctrust\\033[1Cthis\\033[1Cfolder?'; sleep 60 ;;
          *) sleep 60 ;;
        esac
        """
        try? Data(script.utf8).write(to: fakeClaude)
        chmod(fakeClaude.path, 0o755)

        var host = RunnerHost.live
        host.shell = "/bin/sh"
        host.claudeCommand = fakeClaude.path
        host.preScriptTimeout = 20
        host.mcpListTimeout = 20

        out.append("── ScheduleRunner — auto-test (faux claude) ─────────────────────")
        out.append("Racine jetable : \(root.path)")
        out.append("")

        func schedule(preScript: String = "", prompt: String = "Prompt de la probe, assez long.",
                      mcp: [String] = [], enabled: Bool = true) -> Schedule {
            Schedule(name: "Sonde", enabled: enabled, folderPath: folder.path,
                     preScript: preScript,
                     action: .claude(prompt: prompt, model: nil, effort: nil, settingsPath: nil),
                     recurrence: .daily(hour: 10, minute: 0),
                     requiredMCPServers: mcp)
        }

        struct Outcome { let status: RunStatus; let message: String; let sessionID: String?
                         let tty: String; let seconds: TimeInterval }

        /// Un run réel (hors dry-run) sous la racine jetable, relu depuis sa ligne `end`.
        func execute(_ s: Schedule, mode: String, trigger: String = "cli",
                     host: RunnerHost = host) -> Outcome {
            try? fm.removeItem(at: argvFile)
            try? Data(mode.utf8).write(to: modeFile)
            let t0 = Date()
            let result = ScheduleRunner.executeReporting(s, trigger: trigger, dryRun: false, host: host)
            let seconds = Date().timeIntervalSince(t0)
            let end = RunLog.loadLines().last { $0.phase == .end && $0.scheduleID == s.id }
            let tty = end.flatMap { try? String(contentsOf: SchedulePaths.ttyFile(runID: $0.runID)) } ?? ""
            return Outcome(status: result.status, message: end?.message ?? "(pas de ligne end)",
                           sessionID: end?.sessionID, tty: tty, seconds: seconds)
        }
        func detail(_ o: Outcome) -> String {
            "\(o.status.rawValue) · \(o.message) · \(String(format: "%.1f", o.seconds)) s"
        }
        func argv() -> String? { try? String(contentsOf: argvFile) }

        // ── 1. Séquence ──────────────────────────────────────────────────────────
        out.append("— séquence du runner —")
        let preFile = folder.appendingPathComponent("pre.txt")
        let ok = execute(schedule(preScript: "echo PRE | tee pre.txt"), mode: "ok")
        let pre = ok.tty.range(of: "PRE"), fake = ok.tty.range(of: "FAKE-CLAUDE")
        check("run.completed", ok.status == .completed && ok.message == "session terminée"
              && ok.sessionID != nil && fm.fileExists(atPath: preFile.path)
              && pre != nil && fake != nil && pre!.lowerBound < fake!.lowerBound, detail(ok))
        check("run.sessionIDLowercase", ok.sessionID.map { $0 == $0.lowercased()
              && argv()?.contains("--session-id\n\($0)\n") == true } == true, ok.sessionID ?? "nil")

        let trap = "-x 'q' $(y)\nfin"
        let trapped = execute(schedule(prompt: trap), mode: "ok")
        check("run.argvIntact", trapped.status == .completed
              && argv()?.hasSuffix("--\n\(trap)\n") == true
              && argv()?.contains("--permission-mode\ndontAsk\n") == true,
              argv()?.replacingOccurrences(of: "\n", with: "⏎") ?? "argv.txt absent")

        let preFails = execute(schedule(preScript: "exit 4"), mode: "ok")
        check("run.preScriptFails", preFails.status == .failed
              && preFails.message == "préscript en échec (code 4)" && argv() == nil, detail(preFails))

        var shortPre = host
        shortPre.preScriptTimeout = 2
        let hangs = execute(schedule(preScript: "read x"), mode: "ok", host: shortPre)
        check("run.preScriptHangs", hangs.status == .failed
              && hangs.message == "préscript : délai dépassé" && argv() == nil, detail(hangs))

        let missing = execute(schedule(mcp: ["claude.ai Asana"]), mode: "ok")
        check("run.mcpMissing", missing.status == .failed
              && missing.message == "MCP requis indisponibles : claude.ai Asana (needs-auth)"
              && argv() == nil, detail(missing))

        let mcpOK = execute(schedule(mcp: ["plugin:sentry-mcp:sentry"]), mode: "ok")
        check("run.mcpOk", mcpOK.status == .completed, detail(mcpOK))

        let crash = execute(schedule(), mode: "crash")
        check("run.crash", crash.status == .failed
              && crash.message == "claude s'est arrêté avant la fin de sa réponse (code 1)"
              && crash.sessionID != nil, detail(crash))

        let untrusted = execute(schedule(), mode: "trust")
        check("run.untrusted", untrusted.status == .failed
              && untrusted.message == "dossier non approuvé par Claude : ouvrez-le une fois dans Claude Launcher"
              && untrusted.seconds < 10, detail(untrusted))

        var shortSession = host
        shortSession.sessionTimeoutOverride = 2
        let hang = execute(schedule(), mode: "hang", host: shortSession)
        check("run.timeout", hang.status == .timedOut && hang.sessionID != nil
              && hang.tty.contains("FAKE-CLAUDE"), detail(hang))

        let disabled = execute(schedule(enabled: false), mode: "ok", trigger: "launchd")
        check("run.disabled", disabled.status == .skipped
              && disabled.message == "planification désactivée" && argv() == nil, detail(disabled))
        let manual = execute(schedule(enabled: false), mode: "ok", trigger: "manual")
        check("run.disabledManual", manual.status == .completed, detail(manual))

        var gone = schedule()
        gone.folderPath = folder.path + "-supprimé"
        let lost = execute(gone, mode: "ok")
        check("run.missingFolder", lost.status == .failed
              && lost.message == "dossier introuvable : \(gone.folderPath)", detail(lost))

        // ── 2. Verrou inter-process ──────────────────────────────────────────────
        out.append("")
        out.append("— verrou inter-process —")
        let locked = schedule()
        if case .acquired(let fd) = ScheduleRunner.acquireLock(locked.id) {
            let busy = execute(locked, mode: "ok")
            check("run.locked", busy.status == .skipped
                  && busy.message == "un run est déjà en cours" && argv() == nil, detail(busy))
            check("run.lockCloexec", fcntl(fd, F_GETFD) & FD_CLOEXEC != 0,
                  "le fd du verrou ne doit pas passer au préscript ni à claude")
            flock(fd, LOCK_UN)
            close(fd)
        } else {
            check("run.locked", false, "premier verrou non obtenu")
        }

        // ── 3. Politique de notification ─────────────────────────────────────────
        out.append("")
        out.append("— politique de notification —")
        check("échec, délai dépassé et run sauté sous launchd → bannière",
              ScheduleRunner.shouldNotify(status: .failed, trigger: "launchd")
              && ScheduleRunner.shouldNotify(status: .timedOut, trigger: "launchd")
              && ScheduleRunner.shouldNotify(status: .skipped, trigger: "launchd"))
        check("session terminée → PAS de bannière",
              !ScheduleRunner.shouldNotify(status: .completed, trigger: "launchd"))
        check("« Lancer maintenant » et ligne de commande → PAS de bannière",
              !ScheduleRunner.shouldNotify(status: .failed, trigger: "manual")
              && !ScheduleRunner.shouldNotify(status: .failed, trigger: "cli"))

        // ── 4. Dry-run sans aucune trace ─────────────────────────────────────────
        out.append("")
        out.append("— dry-run —")
        let dryRoot = root.appendingPathComponent("dry", isDirectory: true)
        SchedulePaths.overrideRoot = dryRoot
        try? fm.removeItem(at: argvFile)
        let planned = schedule(preScript: "touch dry.txt", mcp: ["claude.ai Asana"])
        let dry = ScheduleRunner.executeReporting(planned, trigger: "launchd", dryRun: true, host: host)
        check("run.dryRunSkipped", dry.status == .skipped, dry.status.rawValue)
        check("run.dryRunReport", dry.report.contains("DRY-RUN")
              && dry.report.contains("touch dry.txt")
              && dry.report.contains("claude.ai Asana (needs-auth)")
              && dry.report.contains("--permission-mode")
              && dry.report.contains("StartCalendarInterval"))
        check("run.dryRunNoTrace", !fm.fileExists(atPath: dryRoot.path)
              && !fm.fileExists(atPath: folder.appendingPathComponent("dry.txt").path)
              && argv() == nil)
        SchedulePaths.overrideRoot = root

        try? fm.removeItem(at: root)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }

    // MARK: - Live (opt-in, vrai claude)

    /// `--sched-selftest live <dossier approuvé>` : un run complet avec le VRAI `claude`
    /// (haiku, environ 0,01 $). Historique et `.tty` sous une racine jetable ; la
    /// conversation, elle, atterrit là où `claude` la range toujours.
    static func live(folderPath: String?) -> String {
        guard let folderPath, !folderPath.isEmpty else {
            return "usage : potof-toolkit --sched-selftest live <dossier approuvé par Claude>"
        }
        var out: [String] = []
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            out.append("  [\(condition ? "OK  " : "ÉCHEC")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
            .standardized.path
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-sched-live-probe-\(UUID().uuidString)", isDirectory: true)
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = nil }

        out.append("── ScheduleRunner — probe live (vrai claude) ────────────────────")
        out.append("Dossier : \(folder)")
        out.append("Approuvé selon ~/.claude.json : "
                   + "\(ClaudeInvocation.isTrusted(folderPath: folder, claudeJSON: try? Data(contentsOf: ClaudeInvocation.claudeJSONURL)))")
        out.append("")

        let schedule = Schedule(
            name: "Sonde live", folderPath: folder,
            action: .claude(prompt: "Réponds juste OK, sans rien faire d'autre.",
                            model: "haiku", effort: nil, settingsPath: nil),
            recurrence: .daily(hour: 10, minute: 0),
            timeoutMinutes: 2,
            requiredMCPServers: ["plugin:sentry-mcp:sentry"])
        let result = ScheduleRunner.executeReporting(schedule, trigger: "cli", dryRun: false)
        let end = RunLog.loadLines().last { $0.phase == .end }
        let ttyURL = end.map { SchedulePaths.ttyFile(runID: $0.runID) }
        let tty = ttyURL.flatMap { try? String(decoding: Data(contentsOf: $0), as: UTF8.self) } ?? ""

        check("live.completed", result.status == .completed,
              "\(result.status.rawValue) · \(end?.message ?? "(pas de ligne end)")")
        check("live.ttyOK", tty.contains("OK"), ttyURL?.path ?? "pas de .tty")
        let transcript = end?.sessionID.map {
            PreviousSessionsStore.projectsRoot
                .appendingPathComponent(PreviousSessionsStore.projectDirName(forPath: folder),
                                        isDirectory: true)
                .appendingPathComponent("\($0).jsonl")
        }
        check("live.transcript", transcript.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              transcript?.path ?? "pas de sessionID")

        if failures == 0 {
            try? FileManager.default.removeItem(at: root)
        } else {
            out.append("")
            out.append("Racine conservée pour inspection : \(root.path)")
            out.append(result.report)
        }
        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
