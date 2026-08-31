import AppKit

// `--help` / `-h` en PREMIÈRE POSITION : imprime l'aide et sort. **Cette garde n'est pas
// cosmétique.** Sans elle, tout argument inconnu tombe jusqu'au `NSApplication.shared` en bas de
// ce fichier et démarre une **SECONDE INSTANCE COMPLÈTE** de l'app — mesuré le 2026-08-11 avec
// `--help`, le process est resté vivant jusqu'à être tué. Or une 2ᵉ instance pose un second lock
// `~/.claude/ide/<port>.lock` (⇒ « deux IDE valides » ⇒ auto-connexion neutralisée des deux côtés)
// et tronque `notifications.jsonl` de l'instance vivante. Un `--help` ne doit jamais coûter ça.
//
// La décision vit dans `CLIHelp` (pur, sans AppKit) pour être vérifiable SANS démarrer le binaire
// — démarrer le binaire est justement l'acte interdit si la garde échoue. Elle est **ancrée sur le
// premier argument** : un `contains("-h")` sur tout l'argv détournait `--sched-selftest -h` et
// `--ide-selftest -h`, qui sortaient en 0 sans exécuter la moindre probe.
//
// Elle ne rejette PAS les argv inconnus (cf. `CLIHelp.isRequested`) : macOS en passe lui-même sur
// certains chemins de lancement, un `exit 64` global casserait le démarrage de l'app.
if CLIHelp.isRequested(CommandLine.arguments) {
    print(CLIHelp.usage)
    exit(0)
}

// Mode diagnostic (hors GUI) : rejoue le contrat protocolaire `claude` ↔ IDE contre le
// binaire `claude` réellement installé. Il vit **avant** `NSApplication` et ne revient
// jamais : ni l'UI, ni l'hôte IDE global de l'app (`IDEHost.shared`, démarré par
// `AppDelegate`) ne sont montés — le banc de test a son propre port et son propre lock.
//
//   potof-toolkit --ide-selftest <dossier> [accept]   serveur de production, branchement manuel
//   potof-toolkit --ide-selftest --e2e [--keep]       test automatique de bout en bout
//
// Détails et compte rendu par point de contrat → `Core/IDEHost/IDESelfTest.swift`
// et `docs/IDE_BRIDGE.md`. N'affecte jamais le lancement normal (drapeau absent).
if let idx = CommandLine.arguments.firstIndex(of: "--ide-selftest") {
    IDESelfTest.run(arguments: CommandLine.arguments, flagIndex: idx)   // -> Never
}

// Superset Scheduler — mode headless exécuté par launchd (un `.plist` par planification).
// Vit ici, avant `NSApplication`, exactement pour la même raison que le mode ci-dessus :
// aucune UI, aucun singleton de l'app, donc aucun risque de marcher sur l'instance GUI en
// cours (le plus vicieux serait `NotificationChannel`, qui tronque `notifications.jsonl`).
// Le prompt de l'utilisateur ne transite JAMAIS par ici : `ProgramArguments` ne porte que
// `["<binaire>", "--run-schedule", "<uuid>"]`, donc aucun texte utilisateur n'atterrit
// dans `~/Library/LaunchAgents`.
//
//   potof-toolkit --run-schedule <uuid> [--dry-run]
//   potof-toolkit --sched-selftest cli | plist | store | run
if let idx = CommandLine.arguments.firstIndex(of: "--run-schedule") {
    ScheduleRunner.run(arguments: CommandLine.arguments, flagIndex: idx)      // -> Never
}
if let idx = CommandLine.arguments.firstIndex(of: "--sched-selftest") {
    SchedulerSelfTest.run(arguments: CommandLine.arguments, flagIndex: idx)   // -> Never
}

// Point d'entrée : NSApplication piloté manuellement (voir AppDelegate).
// Fichier nommé "main.swift" → pas de @main, ce qui est voulu.
// Approche la plus fiable pour afficher et focaliser la fenêtre via `swift run`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
