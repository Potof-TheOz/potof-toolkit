# Potof Toolkit

App macOS native (SwiftUI + AppKit) servant de **toolkit d'outils de dev locaux**.
100 % local : aucun réseau, aucun compte, aucune télémétrie. Premier (et seul) outil
à ce jour : **Claude Launcher** — liste les sous-dossiers d'un dossier racine et lance
`claude` dans iTerm2 au clic. **Zéro dépendance tierce.**

> Le dépôt s'appelle encore `claude-launcher/` (dossier historique) mais le produit,
> l'exécutable et l'app sont **`potof-toolkit`**.

## Commandes essentielles
```bash
swift build                            # compiler
swift run                              # lancer en dev (fenêtre au premier plan)
./Scripts/build-app.sh                 # packager + installer "Potof Toolkit.app" dans ~/Applications
./Scripts/build-app.sh /Applications   # variante (droits admin requis)
```
Détails deploy / debug / données / permissions → **`docs/LIFECYCLE.md`**.

## Contraintes du projet (à respecter)
- macOS **13+**, `swift-tools-version:5.7`, **zéro dépendance externe**.
- **App Sandbox désactivée** — nécessaire pour lister des dossiers arbitraires et piloter
  iTerm2. Ne PAS l'activer.
- Package **exécutable** buildable/lançable en terminal (sans Xcode).
- Structure volontairement simple, pas de MVVM lourd.

## Architecture (`Sources/potof-toolkit/`)
```
main.swift                    Entrée : NSApplication piloté à la main (pas de @main)
App/
  AppDelegate.swift           Fenêtre "Potof Toolkit", menu minimal, icône du Dock
  RootView.swift              Coquille de navigation (barre latérale custom)
Core/
  Tool.swift                  Abstraction d'un outil (id, title, subtitle, icon, view)
  ToolRegistry.swift          ⭐ Registre central = POINT D'EXTENSION UNIQUE
Tools/
  ClaudeLauncher/             Premier outil
    ClaudeLauncherView.swift  UI : dossier racine, recherche, cartes, favoris
    FavoritesStore.swift      Favoris (chemins absolus, UserDefaults)
    FolderItem.swift          Modèle (name + url)
    ITermLauncher.swift       Lancement iTerm2 via AppleScript
Resources/AppIcon.png         Icône 1024×1024 (→ Bundle.module en dev, → .icns en bundle)
```
`Scripts/build-app.sh` : packaging en `.app` (voir LIFECYCLE).

## Ajouter un outil (le geste clé)
1. Créer `Tools/<MonOutil>/<MonOutil>View.swift` — n'importe quelle `View` SwiftUI.
2. Ajouter **une** entrée dans `Core/ToolRegistry.swift` :
   ```swift
   Tool(
       id: "mon-outil",
       title: "Mon Outil",
       subtitle: "Ce que fait l'outil",
       icon: "wrench.and.screwdriver.fill",   // SF Symbol
       view: { MonOutilView() }
   )
   ```
Rien d'autre à câbler : la barre latérale, la sélection et le routage sont automatiques.

## Invariants à NE PAS casser (et pourquoi)
- **`NSHostingController`** (jamais `NSHostingView`) comme `contentViewController` de la fenêtre
  → intégration correcte titlebar/toolbar de SwiftUI en hébergement manuel.
- **Navigation custom, PAS `NavigationSplitView`** dans `RootView`. Raison : le bouton de
  bascule automatique de `NavigationSplitView` ne s'ancre pas dans une fenêtre hébergée
  manuellement et « saute » de position à chaque clic. Le toggle actuel est dans une barre
  supérieure fixe, volontairement. Ne pas « simplifier » en revenant à NavigationSplitView.
- **Focus fenêtre** : `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)`
  sont requis pour que la fenêtre s'affiche et prenne le focus via `swift run`.
- **Double échappement dans `ITermLauncher`** : chemin échappé pour le shell (apostrophe → `'\''`)
  PUIS pour la chaîne AppleScript (`\` → `\\`, `"` → `\"`). Gère espaces/apostrophes/guillemets.
  Ne pas simplifier.
- **Persistance** : `@AppStorage("rootPath")` et `UserDefaults` clé `claudeLauncher.favorites`.
  Stockage par domaine = bundle id → voir LIFECYCLE (dev et app bundlée = 2 stores).
- **Icône** : `applyDockIcon()` pose `NSApp.applicationIconImage` via `Bundle.module`
  (indispensable en `swift run`, non bundlé) ; l'app bundlée obtient aussi l'icône via
  le `.icns` déclaré dans l'`Info.plist`.
