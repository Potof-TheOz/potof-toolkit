import Foundation

/// Harnais d'auto-test du Claude Scheduler — `potof-toolkit --sched-selftest <sous-commande>`.
///
/// Il n'y a **aucun test target** dans `Package.swift`, et l'essentiel du risque de ce
/// chantier est **environnemental** (PATH sous launchd, dossier non approuvé, préscript
/// qui attend une saisie, session qui ne rend pas la main), pas algorithmique. L'idiome du dépôt pour ça, c'est le drapeau
/// d'auto-test (`--ide-selftest`) : chaque lot implémente **son** `probe()` dans **son**
/// fichier, et obtient une commande unique qui prouve qu'il a fini.
///
/// ⚠️ Ce dispatcher est **figé par le socle**. Un lot n'y touche pas : il remplit le
/// `probe()` qui lui appartient.
///
/// Les probes qui écrivent doivent poser `SchedulePaths.overrideRoot` sur un dossier
/// jetable — après un `--sched-selftest`, `~/Library/LaunchAgents` et
/// `~/Library/Application Support/PotofToolkit/scheduler/` doivent être **inchangés**.
enum SchedulerSelfTest {

    static func run(arguments: [String], flagIndex: Int) -> Never {
        let sub = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "help"
        switch sub {
        case "pty":    print(PTYProcessProbe.run())
        case "claude": print(ClaudeInvocationProbe.run())
        case "plist":  print(LaunchAgentPlist.probe())
        case "store":  print(ScheduleStore.probe())
        case "run":    print(ScheduleRunner.probe())
        // Opt-in : vrai `claude` (haiku, environ 0,01 $) dans un dossier déjà approuvé.
        case "live":
            print(ScheduleRunnerProbe.live(
                folderPath: arguments.count > flagIndex + 2 ? arguments[flagIndex + 2] : nil))
        default:       print("sous-commandes : pty | claude | plist | store | run | live <dossier>")
        }
        exit(0)
    }
}
