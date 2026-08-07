import Foundation

/// Auto-test du lot L3 — `potof-toolkit --sched-selftest store`.
///
/// Opère **entièrement** dans un dossier jetable via `SchedulePaths.overrideRoot` : après
/// ce probe, `~/Library/Application Support/PotofToolkit/scheduler/` et
/// `~/Library/LaunchAgents` doivent être **inchangés**. C'est vérifié en fin de rapport.
///
/// Ce qu'il prouve, dans l'ordre : un aller-retour disque fidèle (`Codable` manuel des
/// trois enums compris), le CRUD, la sémantique du JSONL (append-only, deux lignes par
/// run), et surtout **le pliage** — un `start` sans `end` dont le pid est mort doit
/// ressortir en `interrupted`, sans qu'aucun état n'ait à être réconcilié sur disque.
enum ScheduleStoreProbe {

    /// Pid volontairement hors de portée (`kill(2)` → ESRCH) pour simuler un run mort en
    /// route : c'est la seule chose qui départage `running` de `interrupted`.
    private static let deadPID: Int32 = 999_999

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

        // ── Dossier jetable ──────────────────────────────────────────────────────
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("potof-sched-store-probe-\(UUID().uuidString)", isDirectory: true)
        SchedulePaths.overrideRoot = root
        defer { SchedulePaths.overrideRoot = nil }

        let realStore = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PotofToolkit/scheduler",
                                    isDirectory: true)
        let realStoreExistedBefore = FileManager.default.fileExists(atPath: realStore.path)

        let realLaunchAgents = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        /// Nos plists **déjà** présents dans le vrai dossier.
        ///
        /// ⚠️ Cet ensemble n'est pas censé être vide : dès que l'utilisateur crée une
        /// planification depuis l'app bundlée, il y en a. Ce que le probe doit prouver,
        /// c'est qu'il n'en **ajoute ni n'en retire aucun** — pas que le poste n'en a
        /// pas. L'assertion précédente (« aucun plist Potof dans le vrai dossier »)
        /// échouait donc sur toute machine se servant réellement de l'outil, c'est-à-dire
        /// exactement celles où le probe a un intérêt.
        func realPlists() -> Set<String> {
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: realLaunchAgents.path)) ?? []
            return Set(names.filter { $0.hasPrefix(SchedulerService.labelPrefix) })
        }
        let realPlistsBefore = realPlists()

        out.append("── ScheduleStore / RunLog — auto-test (lot L3) ──────────────────")
        out.append("Racine jetable : \(root.path)")
        out.append("isDryRun       : \(SchedulePaths.isDryRun)")
        out.append("")

        let store = ScheduleStore.shared

        // ── 1. Création de deux planifications ───────────────────────────────────
        out.append("— création —")
        let quotidien = Schedule(
            name: "Relevé Sentry — Shopify-Apps",
            action: .supersetAgent(
                agentRef: "dc0a5495-9d1e-45ef-a3c9-b63949e6a48f",
                effort: nil,
                prompt: "Récupère les erreurs de la nuit et écris le rapport du jour."),
            recurrence: .daily(hour: 10, minute: 0),
            target: .permanentWorkspace(
                projectID: "6ccf66bf-1780-40fc-b7e9-256fcd01c51c",
                projectName: "Shopify-Apps",
                workspaceName: "Sentry report",
                branch: "sentry-report",
                baseBranch: "main",
                refreshWorktree: true))

        let hebdo = Schedule(
            name: "Audit hebdomadaire",
            action: .supersetAgent(
                agentRef: Action.defaultAgentRef,
                effort: "xhigh",
                prompt: "Audite les dépendances du projet et résume les CVE ouvertes."),
            recurrence: .weekly(weekdays: [1, 4], hour: 9, minute: 15),
            target: .freshWorkspace(
                projectID: "58c1d955-501f-4aaf-b6b6-995e4f026705",
                projectName: "Potof SKILLS",
                namePrefix: "Audit hebdo",
                branchPrefix: "audit-hebdo",
                baseBranch: "main"))

        store.upsert(quotidien)
        store.upsert(hebdo)
        check("2 planifications en mémoire", store.schedules.count == 2,
              "\(store.schedules.count)")
        check("tri alphabétique appliqué",
              store.schedules.first?.name == "Audit hebdomadaire",
              store.schedules.map(\.name).joined(separator: " | "))

        // ── 2. Aller-retour disque ───────────────────────────────────────────────
        out.append("")
        out.append("— relecture depuis le disque —")
        store.reload()
        store.stopWatchingRuns()          // pas de runloop en CLI : on n'arme rien
        check("2 planifications relues", store.schedules.count == 2,
              "\(store.schedules.count)")

        let releve = store.schedules.first { $0.id == quotidien.id }
        check("l'action a survécu au Codable manuel",
              releve?.action == quotidien.action,
              releve.map { "agentRef=\($0.action.agentRef) effort=\($0.action.effort ?? "nil")" } ?? "absente")
        check("la cadence a survécu", releve?.recurrence == quotidien.recurrence,
              String(describing: releve?.recurrence))
        check("la cible a survécu", releve?.target == quotidien.target)

        let auditRelu = store.schedules.first { $0.id == hebdo.id }
        check("weekly : le Set de jours a survécu (encodé trié)",
              auditRelu?.recurrence == hebdo.recurrence,
              String(describing: auditRelu?.recurrence))
        check("effort non nil conservé", auditRelu?.action.effort == "xhigh",
              auditRelu?.action.effort ?? "nil")

        if let json = try? String(contentsOf: SchedulePaths.schedulesFile, encoding: .utf8) {
            check("le JSON porte bien le niveau `action`", json.contains("\"action\""))
            check("le JSON porte les discriminants `kind`",
                  json.contains("\"kind\" : \"supersetAgent\"")
                  || json.contains("\"kind\":\"supersetAgent\""))
            check("aucun `_0` (synthèse Swift évitée)", !json.contains("\"_0\""))
        } else {
            check("schedules.json lisible", false)
        }

        // ── 3. Désactivation ─────────────────────────────────────────────────────
        out.append("")
        out.append("— désactivation —")
        store.setEnabled(false, id: hebdo.id)
        store.reload()
        store.stopWatchingRuns()
        check("« Audit hebdomadaire » désactivée",
              store.schedules.first { $0.id == hebdo.id }?.enabled == false)
        check("« Relevé Sentry » toujours activée",
              store.schedules.first { $0.id == quotidien.id }?.enabled == true)

        // ── 4. Suppression ───────────────────────────────────────────────────────
        out.append("")
        out.append("— suppression —")
        store.remove(id: hebdo.id)
        store.reload()
        store.stopWatchingRuns()
        check("1 planification restante", store.schedules.count == 1,
              "\(store.schedules.count)")
        check("c'est bien la bonne qui reste",
              store.schedules.first?.id == quotidien.id)

        // ── 5. JSONL : deux runs, dont un interrompu ─────────────────────────────
        out.append("")
        out.append("— historique (JSONL append-only) —")

        // Run A : complet, `launched`.
        let runA = UUID()
        let logA = RunLog(runID: runA, scheduleID: quotidien.id, trigger: "launchd")
        logA.start()
        logA.note("garde worktree : OK")
        logA.finish(status: .launched,
                    message: "agent dc0a5495-… lancé",
                    workspaceID: "c54cbbf3-0000-0000-0000-000000000000",
                    worktreePath: "/Users/x/ws")

        // Run B : `start` SANS `end`, pid mort ⇒ doit se plier en `interrupted`.
        let runB = UUID()
        RunLog.append(RunLine.start(runID: runB, scheduleID: quotidien.id,
                                    trigger: "launchd", pid: deadPID, at: Date()))

        let lines = RunLog.loadLines()
        check("3 lignes écrites (start+end pour A, start seul pour B)",
              lines.count == 3, "\(lines.count)")
        check("une seule ligne `end`",
              lines.filter { $0.phase == .end }.count == 1)

        let records = RunLog.recent(scheduleID: quotidien.id, limit: 10)
        check("2 runs pliés", records.count == 2, "\(records.count)")

        let a = records.first { $0.id == runA }
        let b = records.first { $0.id == runB }
        check("run A ⇒ launched", a?.status == .launched,
              a.map { "\($0.status.rawValue) · \($0.message)" } ?? "absent")
        check("run A a une durée", a?.duration != nil)
        check("run A porte son logPath", a?.logPath != nil)
        check("run B ⇒ interrupted (pid mort, pas de `end`)",
              b?.status == .interrupted,
              b.map { "\($0.status.rawValue) · \($0.message)" } ?? "absent")
        check("run B n'a pas de date de fin", b?.endedAt == nil)
        check("tri du plus récent au plus ancien",
              records.first?.startedAt ?? .distantPast >= records.last?.startedAt ?? .distantFuture)

        // Le pliage ne doit rien réconcilier sur disque : le JSONL est intact.
        check("le JSONL n'a pas été réécrit par le pliage",
              RunLog.loadLines().count == 3, "\(RunLog.loadLines().count)")

        // `launched` ne notifie pas ; `failed`/`skipped` oui (§6.7).
        check("RunStatus.launched ne déclenche pas de bannière",
              RunStatus.launched.deservesNotification == false)
        check("RunStatus.skipped en déclenche une",
              RunStatus.skipped.deservesNotification)

        // ── 6. Message plafonné ──────────────────────────────────────────────────
        out.append("")
        out.append("— plafond du champ `message` —")
        let runC = UUID()
        let longMessage = String(repeating: "x", count: 2_000)
        RunLog(runID: runC, scheduleID: quotidien.id, trigger: "manual")
            .finish(status: .failed, message: longMessage, workspaceID: nil, worktreePath: nil)
        let cLine = RunLog.loadLines().first { $0.runID == runC }
        check("message tronqué à \(RunLine.maxMessageLength) caractères",
              cLine?.message?.count == RunLine.maxMessageLength,
              "\(cLine?.message?.count ?? -1)")

        // ── 7. Compaction EN PLACE ───────────────────────────────────────────────
        // Le chemin le plus risqué du lot : on réécrit un fichier que le runner headless
        // peut être en train d'appender. L'assertion qui compte est **l'inode inchangé** —
        // un `rename` (ou une écriture atomique, qui en fait un) ferait écrire un appender
        // déjà ouvert dans un fichier devenu invisible, et ses runs disparaîtraient.
        out.append("")
        out.append("— compaction en place —")

        let runsURL = SchedulePaths.runsFile
        func inode(_ url: URL) -> UInt64? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber]
                as? UInt64
        }
        func fileSize(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }

        // Gonfler au-delà du seuil. Le message porte le rembourrage : c'est ce qui rend
        // la ligne réaliste (une ligne courte donnerait un fichier de 300 lignes).
        let padding = String(repeating: "y", count: RunLine.maxMessageLength)
        var generated = 0
        while fileSize(runsURL) <= RunLog.compactionThresholdBytes {
            RunLog.append(RunLine.end(
                runID: UUID(), scheduleID: quotidien.id, at: Date(),
                status: .launched, message: padding,
                workspaceID: nil, worktreePath: nil, logPath: nil))
            generated += 1
        }

        let inodeBefore = inode(runsURL)
        let linesBefore = RunLog.loadLines().count
        let sizeBefore = fileSize(runsURL)
        out.append("  \(generated) lignes générées · \(sizeBefore) octets · \(linesBefore) lignes")
        check("seuil de compaction dépassé", sizeBefore > RunLog.compactionThresholdBytes)

        RunLog.compactIfNeeded()

        let linesAfter = RunLog.loadLines().count
        check("compacté à \(RunLog.compactionKeepLines) lignes",
              linesAfter == RunLog.compactionKeepLines, "\(linesAfter)")
        check("le fichier a bien rétréci", fileSize(runsURL) < sizeBefore,
              "\(sizeBefore) → \(fileSize(runsURL))")
        check("⭐ INODE INCHANGÉ (réécriture en place, pas de rename)",
              inodeBefore != nil && inode(runsURL) == inodeBefore,
              "\(inodeBefore.map(String.init) ?? "?") → \(inode(runsURL).map(String.init) ?? "?")")
        check("toutes les lignes restantes sont décodables",
              RunLog.loadLines().count == linesAfter)

        // Ré-appel immédiat : sous le seuil, ce doit être un no-op strict.
        let inodeStable = inode(runsURL)
        RunLog.compactIfNeeded()
        check("second appel sous le seuil = no-op",
              RunLog.loadLines().count == linesAfter && inode(runsURL) == inodeStable)

        // ── 8. Effets de bord ────────────────────────────────────────────────────
        out.append("")
        out.append("— effets de bord —")
        let realStoreExistsAfter = FileManager.default.fileExists(atPath: realStore.path)
        check("le dossier scheduler RÉEL n'a pas été créé par le probe",
              realStoreExistsAfter == realStoreExistedBefore,
              realStoreExistsAfter ? "présent (déjà avant : \(realStoreExistedBefore))" : "absent")

        let realPlistsAfter = realPlists()
        let drift = realPlistsAfter.symmetricDifference(realPlistsBefore).sorted()
        check("le VRAI ~/Library/LaunchAgents est INCHANGÉ",
              drift.isEmpty,
              drift.isEmpty
                  ? "\(realPlistsBefore.count) plist(s) Potof avant comme après"
                  : "écart : \(drift.joined(separator: ", "))")

        let dryPlists = (try? FileManager.default.contentsOfDirectory(
            atPath: SchedulePaths.launchAgentsDirectory.path))?.sorted() ?? []
        out.append("  plists écrits dans le dossier jetable : \(dryPlists.count)")
        for name in dryPlists { out.append("    \(name)") }

        // ── Nettoyage ────────────────────────────────────────────────────────────
        try? FileManager.default.removeItem(at: root)

        out.append("")
        out.append(failures == 0
                   ? "RÉSULTAT : tous les invariants sont vérifiés."
                   : "RÉSULTAT : \(failures) ÉCHEC(S).")
        return out.joined(separator: "\n")
    }
}
