import Foundation

/// Auto-test de `ClaudeInvocation` et `MCPList` — `potof-toolkit --sched-selftest claude`.
///
/// Fonctions pures : aucun process, aucun écrit.
enum ClaudeInvocationProbe {

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

        /// Les `command` de `hooks.Stop[*].hooks[*]`.
        func stopCommands(_ settings: [String: Any]) -> [String] {
            let hooks = settings["hooks"] as? [String: Any]
            let stop = hooks?["Stop"] as? [[String: Any]] ?? []
            return stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }

        func settingsObject(_ user: Data?, _ marker: URL) -> [String: Any]? {
            guard let data = try? ClaudeInvocation.runSettings(userSettings: user, stopMarker: marker) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        out.append("── ClaudeInvocation / MCPList — auto-test ───────────────────────")
        out.append("")

        let sid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let settings = URL(fileURLWithPath: "/a b/r.settings.json")
        check("claude.args", ClaudeInvocation.claudeArguments(prompt: "Fais X", sessionID: sid,
              settingsFile: settings, model: nil, effort: nil)
            == ["--session-id", "11111111-2222-3333-4444-555555555555", "--permission-mode", "dontAsk",
                "--settings", "/a b/r.settings.json", "--", "Fais X"])
        check("claude.argsModelEffort", ClaudeInvocation.claudeArguments(prompt: "p", sessionID: sid,
              settingsFile: settings, model: "haiku", effort: "high")
            == ["--session-id", sid.uuidString.lowercased(), "--permission-mode", "dontAsk",
                "--settings", "/a b/r.settings.json", "--model", "haiku", "--effort", "high", "--", "p"])
        check("claude.argsDashPrompt", ClaudeInvocation.claudeArguments(prompt: "-rf $(x) 'q'\nfin",
              sessionID: sid, settingsFile: settings, model: nil, effort: nil).last == "-rf $(x) 'q'\nfin")
        check("claude.shellArgs", ClaudeInvocation.claudeShellArguments(shell: "/bin/zsh",
              claudeCommand: "claude", claudeArguments: ["--", "p"])
            == ["/bin/zsh", "-l", "-i", "-c", "exec 'claude' \"$@\"", "claude", "--", "p"])
        check("claude.shellPlain", ClaudeInvocation.shellArguments(shell: "/bin/zsh", command: "echo hi")
            == ["/bin/zsh", "-l", "-i", "-c", "echo hi"])
        check("claude.shellFallback", ClaudeInvocation.shell(from: ["SHELL": "/opt/homebrew/bin/fish"]) == "/bin/zsh"
              && ClaudeInvocation.shell(from: [:]) == "/bin/zsh")
        check("claude.shellKept", ClaudeInvocation.shell(from: ["SHELL": "/bin/bash"]) == "/bin/bash")

        let env = ClaudeInvocation.environment(base: ["PATH": "/usr/bin", "HOME": "/h", "CLAUDECODE": "1",
              "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SSE_PORT": "1234", "POTOF_SESSION_ID": "x"])
        check("claude.envAdds", Set(env).isSuperset(of: ["CLAUDE_CODE_AUTO_CONNECT_IDE=false",
              "TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8", "HOME=/h", "PATH=/usr/bin"]))
        check("claude.envStrips", !env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_CHILD_SESSION=")
              || $0.hasPrefix("CLAUDE_CODE_SSE_PORT=") || $0.hasPrefix("POTOF_SESSION_ID=") })
        check("claude.envKeepsLang", ClaudeInvocation.environment(base: ["LANG": "fr_FR.UTF-8"]).contains("LANG=fr_FR.UTF-8"))

        let marker = URL(fileURLWithPath: "/x y/it's.stop")
        let s1 = settingsObject(nil, marker)
        check("claude.settingsHook", s1.map(stopCommands) == ["touch '/x y/it'\\''s.stop'"])
        let user = #"{"permissions":{"allow":["Read"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo u"}]}]}}"#
        let s2 = settingsObject(Data(user.utf8), marker)
        check("claude.settingsMerge", s2.map(stopCommands) == ["echo u", "touch '/x y/it'\\''s.stop'"]
              && (s2?["permissions"] as? [String: Any])?["allow"] as? [String] == ["Read"])
        check("claude.settingsInvalid", settingsObject(Data("[1]".utf8), marker) == nil
              && settingsObject(Data("{".utf8), marker) == nil)

        let cj = Data(#"{"projects":{"/p/ok":{"hasTrustDialogAccepted":true},"/p/no":{"hasTrustDialogAccepted":false}}}"#.utf8)
        check("claude.trusted", ClaudeInvocation.isTrusted(folderPath: "/p/ok/", claudeJSON: cj))
        check("claude.untrusted", !ClaudeInvocation.isTrusted(folderPath: "/p/no", claudeJSON: cj)
              && !ClaudeInvocation.isTrusted(folderPath: "/p/autre", claudeJSON: cj)
              && !ClaudeInvocation.isTrusted(folderPath: "/p/ok", claudeJSON: nil))

        // MCPList — extrait réel de `claude mcp list` du 2026-10-30, avec couleurs ANSI ajoutées
        let sample = "Checking MCP server health…\r\n\r\n"
            + "claude.ai Asana: https://mcp.asana.com/sse - ! Needs authentication\r\n"
            + "plugin:sentry-mcp:sentry: https://mcp.sentry.dev/mcp (HTTP) - \u{1B}[32m✔ Connected\u{1B}[39m\r\n"
            + "webstorm: http://127.0.0.1:64342/sse (SSE) - ✘ Failed to connect — SSE error: ECONNREFUSED\r\n"
            + "n8n-prod: /Users/x/.nvm/versions/node/v26.5.0/bin/n8n-mcp  - ✔ Connected\r\n"
        let states = MCPList.parse(sample)
        check("mcp.parse", states.count == 4 && states["plugin:sentry-mcp:sentry"] == .connected
              && states["claude.ai Asana"] == .needsAuth && states["n8n-prod"] == .connected
              && { if case .failed = states["webstorm"] { return true }; return false }())
        check("mcp.unavailable", MCPList.unavailable(required: ["n8n-prod", "claude.ai Asana", "absent"], in: states)
              == ["claude.ai Asana (needs-auth)", "absent (absent)"])
        check("mcp.unavailableFailed", MCPList.unavailable(required: ["webstorm"], in: states)
              .first?.hasPrefix("webstorm (échec : ") == true)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
