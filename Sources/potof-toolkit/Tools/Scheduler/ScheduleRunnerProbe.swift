import Foundation

/// Auto-test du lot L5 — `potof-toolkit --sched-selftest run`.
///
/// Opère dans un dossier jetable (`SchedulePaths.overrideRoot`) et n'appelle de la CLI
/// `superset` que des commandes de **lecture**. Il ne crée aucun workspace, ne lance aucun
/// agent, n'écrit aucune ligne d'historique et ne fait apparaître aucune bannière.
///
/// Ce qu'il prouve : la politique de notification, la garde de bundle du canal de remise,
/// l'exclusion inter-process du verrou, et — le plus important — qu'un **dry-run ne laisse
/// aucune trace**, condition sans laquelle on n'oserait pas s'en servir pour déboguer.
enum ScheduleRunnerProbe {

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

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-sched-runner-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = nil }

        out.append("── ScheduleRunner — auto-test (lot L5) ──────────────────────────")
        out.append("Racine jetable : \(root.path)")
        out.append("")

        // ── 1. Politique de notification ─────────────────────────────────────────
        out.append("— politique de notification (§6.7) —")
        check("échec sous launchd → bannière",
              ScheduleRunner.shouldNotify(status: .failed, trigger: "launchd"))
        check("run sauté sous launchd → bannière",
              ScheduleRunner.shouldNotify(status: .skipped, trigger: "launchd"))
        check("agent lancé → PAS de bannière (un succès n'a rien à annoncer)",
              !ScheduleRunner.shouldNotify(status: .launched, trigger: "launchd"))
        check("« Lancer maintenant » → PAS de bannière (l'utilisateur regarde l'écran)",
              !ScheduleRunner.shouldNotify(status: .failed, trigger: "manual"))
        check("lancement manuel en ligne de commande → PAS de bannière",
              !ScheduleRunner.shouldNotify(status: .failed, trigger: "cli"))

        // ── 2. Canal de remise ───────────────────────────────────────────────────
        out.append("")
        out.append("— canal de remise —")
        // `canPost` est faux hors bundle : c'est le cas quand ce probe tourne depuis
        // `.build/debug/`. Sous launchd, le runner vit dans le `.app` et la garde passe.
        out.append("  bundle courant : \(Bundle.main.bundleURL.lastPathComponent)")
        check("la garde de bundle répond sans planter",
              ScheduleNotifier.canPost || !ScheduleNotifier.canPost,
              ScheduleNotifier.canPost ? "bundlé → bannières possibles"
                                       : "non bundlé → bannières ignorées (attendu en dev)")
        if !ScheduleNotifier.canPost {
            let outcome = ScheduleNotifier.post(title: "t", subtitle: "t", body: "t")
            check("hors bundle, `post` refuse proprement au lieu de planter",
                  outcome.contains("non bundlé"), outcome)
        }

        // ── 3. Exclusion du verrou ───────────────────────────────────────────────
        out.append("")
        out.append("— verrou inter-process —")
        let lockID = UUID()
        let first = ScheduleRunner.acquireLock(lockID)
        var firstDescriptor: Int32?
        if case .acquired(let fd) = first { firstDescriptor = fd }
        check("premier verrou obtenu", firstDescriptor != nil)

        // Deuxième prise DANS LE MÊME process : `flock` étant associé à la description de
        // fichier ouverte (et pas au process), un second `open` + `flock` se voit bien
        // refuser. C'est ce qui exclut un tir launchd pendant un « Lancer maintenant ».
        let second = ScheduleRunner.acquireLock(lockID)
        check("second verrou refusé (busy)", second == .busy, "\(second)")

        if let firstDescriptor {
            flock(firstDescriptor, LOCK_UN)
            close(firstDescriptor)
        }
        let third = ScheduleRunner.acquireLock(lockID)
        var thirdDescriptor: Int32?
        if case .acquired(let fd) = third { thirdDescriptor = fd }
        check("verrou repris après libération", thirdDescriptor != nil)
        if let thirdDescriptor {
            flock(thirdDescriptor, LOCK_UN)
            close(thirdDescriptor)
        }

        // ── 4. Dry-run complet, sans aucune trace ────────────────────────────────
        out.append("")
        out.append("— dry-run de bout en bout —")

        guard SupersetCLI.isInstalled() else {
            out.append("  (Superset introuvable : dry-run non exercé)")
            try? FileManager.default.removeItem(at: root)
            out.append("")
            out.append(failures == 0 ? "RÉSULTAT : invariants vérifiés (dry-run non exercé)."
                                     : "RÉSULTAT : \(failures) ÉCHEC(S).")
            return out.joined(separator: "\n")
        }

        // On vise un workspace RÉEL, pour que la résolution par (projet, nom) soit
        // réellement exercée — c'est le point que le matching par nom seul casserait.
        let sample = SupersetCLI.workspaces()?.first { ($0.worktreePath?.isEmpty == false) }
        guard let sample, let projectID = sample.projectId else {
            out.append("  (aucun workspace exploitable : dry-run non exercé)")
            try? FileManager.default.removeItem(at: root)
            out.append("")
            out.append(failures == 0 ? "RÉSULTAT : invariants vérifiés (dry-run non exercé)."
                                     : "RÉSULTAT : \(failures) ÉCHEC(S).")
            return out.joined(separator: "\n")
        }

        let schedule = Schedule(
            name: "Sonde — \(sample.name)",
            action: .supersetAgent(
                agentRef: Action.defaultAgentRef,
                effort: nil,
                prompt: "Sonde d'auto-test : ce prompt n'est jamais envoyé à un agent."),
            recurrence: .daily(hour: 10, minute: 0),
            target: .permanentWorkspace(
                projectID: projectID,
                projectName: sample.projectName ?? "",
                workspaceName: sample.name,
                branch: sample.branch ?? "main",
                baseBranch: "main",
                refreshWorktree: true))

        let outcome = ScheduleRunner.executeReporting(schedule, trigger: "cli", dryRun: true)

        check("le dry-run conclut en `skipped` (aucun agent lancé)",
              outcome.status == .skipped, outcome.status.rawValue)
        check("le rapport s'annonce comme un dry-run",
              outcome.report.contains("DRY-RUN"))
        check("le rapport contient l'argv de `agents create`",
              outcome.report.contains("agents create"))
        check("le rapport contient le prompt intégral",
              outcome.report.contains("Sonde d'auto-test"))
        check("le rapport contient le .plist qui serait installé",
              outcome.report.contains("StartCalendarInterval"))
        check("le rapport annonce le fetch/reset SANS l'exécuter",
              outcome.report.contains("non exécuté"))
        // ⭐ Le point qui rend le dry-run utile : un garde-fou qui déclenche est ANNOTÉ,
        // il n'interrompt pas l'impression du plan. Sinon l'outil de debug ne montre
        // justement rien le jour où il y a quelque chose à comprendre.
        check("un garde-fou déclenché n'interrompt pas le plan",
              !outcome.report.contains("⚠︎") || outcome.report.contains("agents create"),
              outcome.report.contains("⚠︎") ? "un garde-fou a bien été annoté" : "aucun garde-fou déclenché")
        check("la résolution a bien trouvé le workspace par (projet, nom)",
              outcome.report.contains(sample.id), sample.name)

        // ⭐ L'assertion qui autorise à se servir du dry-run pour déboguer.
        let jsonlExists = FileManager.default.fileExists(atPath: SchedulePaths.runsFile.path)
        check("AUCUNE ligne d'historique écrite par le dry-run", !jsonlExists)
        let lockExists = FileManager.default.fileExists(
            atPath: SchedulePaths.lockFile(scheduleID: schedule.id).path)
        check("AUCUN verrou posé par le dry-run", !lockExists)

        out.append("")
        out.append("  — plan produit —")
        for line in outcome.report.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(24) {
            out.append("  \(line)")
        }
        out.append("  … (\(outcome.report.split(separator: "\n").count) lignes au total)")

        try? FileManager.default.removeItem(at: root)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
