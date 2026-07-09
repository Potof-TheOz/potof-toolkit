import AppKit

// Mode diagnostic (hors GUI) : lance le serveur d'intégration IDE **de production**
// en isolation, pour le valider contre un vrai `claude` (connexion + openDiff →
// refus, sans écrire de fichier). Usage :
//   potof-toolkit --ide-selftest <dossier>
// Le port (éphémère) est imprimé sur stdout ; le lock est écrit dans ~/.claude/ide.
// Voir docs/IDE_BRIDGE.md. N'affecte jamais le lancement normal (drapeau absent).
if let idx = CommandLine.arguments.firstIndex(of: "--ide-selftest") {
    let folder = CommandLine.arguments.count > idx + 1
        ? URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let server = IDEServer(sessionID: UUID(), workspace: folder)
    guard let port = server.port else {
        FileHandle.standardError.write(Data("ide-selftest: réservation de port échouée\n".utf8))
        exit(1)
    }
    // Par défaut onOpenDiff reste nil → refus systématique. Avec l'argument
    // `accept`, on simule un clic « Accepter » (valide le chemin FILE_SAVED :
    // c'est alors Claude qui écrit le fichier).
    if CommandLine.arguments.contains("accept") {
        server.onOpenDiff = { _, done in done(.saved) }
    }
    server.start()
    print("PORT=\(port)")
    fflush(stdout)
    dispatchMain()
}

// Point d'entrée : NSApplication piloté manuellement (voir AppDelegate).
// Fichier nommé "main.swift" → pas de @main, ce qui est voulu.
// Approche la plus fiable pour afficher et focaliser la fenêtre via `swift run`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
