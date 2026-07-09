import AppKit

// Point d'entrée : NSApplication piloté manuellement (voir AppDelegate).
// Fichier nommé "main.swift" → pas de @main, ce qui est voulu.
// Approche la plus fiable pour afficher et focaliser la fenêtre via `swift run`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
