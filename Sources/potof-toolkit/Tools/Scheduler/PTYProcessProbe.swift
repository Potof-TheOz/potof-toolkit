import Foundation

/// Auto-test de `PTYProcess` — `potof-toolkit --sched-selftest pty`.
///
/// Chaque cas lance `/bin/sh -c '<script>' …` dans un dossier jetable, avec une env
/// minimale. Aucun `claude`, aucun écrit hors du dossier jetable : le vrai dossier du
/// scheduler et `~/Library/LaunchAgents` restent inchangés.
enum PTYProcessProbe {

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

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-pty-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        out.append("── PTYProcess — auto-test ───────────────────────────────────────")
        out.append("Dossier jetable : \(dir.path)")
        out.append("")

        /// `/bin/sh -c script argv0 args…` : `$0` = `argv0`, `$1…` = `args`.
        func req(_ script: String, argv0: String = "sh", args: [String] = [],
                 tty: URL? = nil, marker: URL? = nil, timeout: TimeInterval,
                 trust: Bool = false, keep: Bool = false) -> PTYRequest {
            PTYRequest(executable: "/bin/sh",
                       arguments: ["sh", "-c", script, argv0] + args,
                       environment: ["PATH=/usr/bin:/bin"],
                       directory: dir.path,
                       ttyFile: tty,
                       timeout: timeout,
                       stopMarker: marker,
                       detectTrustDialog: trust,
                       keepOutput: keep)
        }

        // pty.exited + pty.recorded
        let tty1 = dir.appendingPathComponent("exited.tty")
        let r1 = PTYProcess.run(req("printf hello; exit 3", tty: tty1, timeout: 10))
        check("pty.exited", r1.end == .exited(code: 3), "\(r1.end)")
        check("pty.recorded", (try? String(contentsOf: tty1))?.contains("hello") == true)

        // pty.stopMarker — le script pose le marqueur puis attend « /exit »
        let marker = dir.appendingPathComponent("hook.stop")
        let r2 = PTYProcess.run(req("touch \"$1\"; read l; [ \"$l\" = /exit ] && exit 0; exit 9",
                                    args: [marker.path], marker: marker, timeout: 20))
        check("pty.stopMarker", r2.end == .stopped(code: 0), "\(r2.end)")

        // pty.timeout — rend la main en moins de timeout + killGrace + 2 s
        let t0 = Date()
        let r3 = PTYProcess.run(req("sleep 60", timeout: 1))
        let elapsed = Date().timeIntervalSince(t0)
        check("pty.timeout", r3.end == .timedOut && elapsed < 6,
              "\(r3.end) en \(String(format: "%.1f", elapsed)) s")

        // pty.killsGroup — le petit-fils écrit son pid, il doit être mort après le délai
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        _ = PTYProcess.run(req("sleep 60 & echo $! > \"$1\"; wait", args: [pidFile.path], timeout: 1))
        let grandchild = (try? String(contentsOf: pidFile))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var dead = false
        if let grandchild {
            // Le SIGKILL est parti ; on laisse au plus 2 s à launchd pour récolter le zombie.
            for _ in 0..<40 {
                if kill(grandchild, 0) != 0 { dead = true; break }
                usleep(50_000)
            }
        }
        check("pty.killsGroup", grandchild != nil && dead,
              grandchild.map { "pid \($0)" } ?? "pid illisible")

        // pty.killsBackgroundJob — cas de la revue : un shell INTERACTIF avec un job de fond.
        // Les arguments sont les vrais (`ClaudeInvocation.shellArguments`, donc `+m`) ; on
        // n'y insère que de quoi ne pas sourcer les rc de la machine. Sans `+m`, le job
        // partait dans son propre groupe et survivait au kill (vérifié en retirant `+m`).
        let interactiveShells: [(path: String, skipRC: [String])] = [
            ("/bin/zsh", ["-f"]), ("/bin/bash", ["--noprofile", "--norc"])]
        for (index, shell) in interactiveShells.enumerated()
        where FileManager.default.isExecutableFile(atPath: shell.path) {
            let jobPidFile = dir.appendingPathComponent("job-\(index).pid")
            let argv = ClaudeInvocation.shellArguments(
                shell: shell.path, command: "/bin/sleep 71 & echo $! > '\(jobPidFile.path)'; wait")
            let started = Date()
            let result = PTYProcess.run(PTYRequest(
                executable: shell.path,
                arguments: [argv[0]] + shell.skipRC + argv.dropFirst(),
                environment: ["PATH=/usr/bin:/bin", "HOME=\(dir.path)"],
                directory: dir.path, ttyFile: nil, timeout: 1, stopMarker: nil,
                detectTrustDialog: false, keepOutput: false))
            let jobPid = (try? String(contentsOf: jobPidFile))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            var jobDead = false
            if let jobPid {
                for _ in 0..<40 {
                    if kill(jobPid, 0) != 0 { jobDead = true; break }
                    usleep(50_000)
                }
                if !jobDead { kill(jobPid, SIGKILL) }       // ne laisse rien derrière une probe en échec
            }
            check("pty.killsBackgroundJob.\((shell.path as NSString).lastPathComponent)",
                  result.end == .timedOut && jobPid != nil && jobDead,
                  "\(result.end) en \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
                  + (jobPid.map { "job \($0) \(jobDead ? "mort" : "VIVANT")" } ?? "pid illisible"))
        }

        // pty.trustDialog — séquences de déplacement du curseur entre les mots, comme le vrai TUI
        let r5 = PTYProcess.run(req(
            "printf 'Do you\\033[1Ctrust\\033[1Cthis\\033[1Cfolder?'; sleep 60",
            timeout: 30, trust: true))
        check("pty.trustDialog", r5.end == .trustDialog, "\(r5.end)")

        // pty.keepOutput
        let r6 = PTYProcess.run(req("printf 'a\\nb'", timeout: 10, keep: true))
        check("pty.keepOutput", String(decoding: r6.output, as: UTF8.self).contains("b"))

        // pty.argvIntact — aucun shell ne ré-interprète les arguments
        let outBase = dir.appendingPathComponent("argv")
        let outFile = URL(fileURLWithPath: outBase.path + ".out")
        _ = PTYProcess.run(req("printf '%s\\n' \"$@\" > \"$0.out\"", argv0: outBase.path,
                               args: ["a b", "$(x)", "c'd", "-z"], timeout: 10))
        check("pty.argvIntact", (try? String(contentsOf: outFile)) == "a b\n$(x)\nc'd\n-z\n")

        // pty.readerIncremental — la vue « Session » relit le `.tty` par morceaux
        let readerFile = dir.appendingPathComponent("reader.tty")
        try? Data("ab".utf8).write(to: readerFile)
        let first = TTYFileReader.read(readerFile, from: 0)
        if let handle = try? FileHandle(forWritingTo: readerFile) {
            handle.seekToEndOfFile()
            handle.write(Data("c".utf8))
            try? handle.close()
        }
        let second = TTYFileReader.read(readerFile, from: first.offset)
        let absent = TTYFileReader.read(dir.appendingPathComponent("absent.tty"), from: 7)
        check("pty.readerIncremental",
              String(decoding: first.data, as: UTF8.self) == "ab" && first.offset == 2
                  && String(decoding: second.data, as: UTF8.self) == "c" && second.offset == 3
                  && absent.data.isEmpty && absent.offset == 7,
              "\(first.offset) / \(second.offset) / \(absent.offset)")

        // pty.readerSliced — lecture par tranches : jamais plus que `limit`, et la suite reprend au bon octet
        try? Data("abcdefg".utf8).write(to: readerFile)
        var sliced = ""
        var cursor: UInt64 = 0
        var reads = 0
        while reads < 10 {
            let part = TTYFileReader.read(readerFile, from: cursor, limit: 3)
            if part.data.isEmpty { break }
            sliced += String(decoding: part.data, as: UTF8.self) + "|"
            cursor = part.offset
            reads += 1
        }
        check("pty.readerSliced", sliced == "abc|def|g|" && cursor == 7, sliced)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
