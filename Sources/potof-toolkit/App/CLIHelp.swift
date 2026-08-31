import Foundation

/// Décision « cet argv demande-t-il l'aide ? » — **pure**, donc vérifiable sans démarrer l'app.
///
/// Pourquoi un fichier à part plutôt qu'un `if` dans `main.swift` : le dispatch d'argv y vit en
/// instructions top-level, inatteignable depuis une probe. Or démarrer le binaire pour tester la
/// garde est précisément l'acte interdit du dépôt (2ᵉ instance ⇒ second lock
/// `~/.claude/ide/<port>.lock` ⇒ auto-connexion `claude` neutralisée des deux côtés, et
/// `NotificationChannel.start()` tronque le `notifications.jsonl` de l'instance vivante). Isolée
/// ici, la décision se compile et s'exerce seule, sans AppKit et sans effet de bord.
enum CLIHelp {

    /// Drapeaux d'aide reconnus — en **PREMIÈRE POSITION UNIQUEMENT**.
    ///
    /// ⚠️ L'ancrage n'est pas cosmétique. Un `CommandLine.arguments.contains("-h")` non ancré
    /// détournait `--sched-selftest -h` et `--ide-selftest -h` : la garde étant évaluée avant les
    /// trois autres modes, ces commandes imprimaient l'aide et sortaient en **0** sans avoir
    /// exécuté la moindre probe. Faux vert sur les seuls diagnostics du dépôt — il n'y a pas de
    /// test target, ce sont eux qui font foi.
    static let flags: Set<String> = ["--help", "-h"]

    /// `true` seulement si le premier argument après le nom du binaire demande l'aide.
    ///
    /// Volontairement **étroit** : on ne rejette pas les argv inconnus. Un `exit 64` sur tout
    /// argument non reconnu refuserait de démarrer quand macOS passe lui-même des arguments
    /// (`-psn_0_…` via LaunchServices, `-NSDocumentRevisionsDebugMode YES` sous Xcode,
    /// `-AppleLanguages (…)`), transformant un défaut de confort en panne de démarrage.
    static func isRequested(_ arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first else { return false }
        return flags.contains(first)
    }

    /// Aide imprimée sur stdout. Les crochets suivent le contrat RÉEL de chaque mode :
    /// `IDESelfTest.runManual` retombe sur le répertoire courant si le dossier manque, et
    /// `SchedulerSelfTest.run` retombe sur la liste des sous-commandes si elle manque.
    static let usage = """
    potof-toolkit — toolkit d'outils de dev locaux (macOS).

    Sans argument : lance l'application (fenêtre « Potof Toolkit »).

      --help, -h                              cette aide (en 1ʳᵉ position)

    Modes hors GUI (ils vivent avant NSApplication et ne montent aucune UI) :
      --run-schedule <uuid> [--dry-run]       exécute une planification du Superset Scheduler
                                              (mode headless appelé par launchd ; --dry-run
                                              imprime le plan sans écrire d'historique ni
                                              poser de verrou)
      --sched-selftest [cli|plist|store|run]  auto-tests du Superset Scheduler
                                              (sans sous-commande : liste les sous-commandes)

    ⚠️ Bancs d'essai du pont IDE — PAS des diagnostics anodins : ils montent le serveur IDE de
       PRODUCTION, posent un second verrou dans le vrai $HOME et ne rendent jamais la main.
       Ne PAS les lancer pendant que l'app tourne (deux IDE « valides » sur le même arbre
       neutralisent l'auto-connexion `claude` des deux côtés). Cf. docs/IDE_BRIDGE.md.
      --ide-selftest [dossier] [accept]       branchement manuel (défaut : répertoire courant)
      --ide-selftest --e2e [--keep]           bout en bout

    Tout autre argument n'est PAS rejeté : il tombe dans le lancement normal de la GUI.
    Docs : docs/SCHEDULER.md, docs/IDE_BRIDGE.md, docs/LIFECYCLE.md
    """
}
