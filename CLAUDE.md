# Potof Toolkit

App macOS native (SwiftUI + AppKit) servant de **toolkit d'outils de dev locaux**.
100 % local : aucun réseau, aucun compte, aucune télémétrie. Premier (et seul) outil
à ce jour : **Claude Launcher** — liste les sous-dossiers d'un dossier racine et lance
`claude` dans un **terminal embarqué** (SwiftTerm) affiché **au centre de l'app**. Les
sessions sont **possédées par l'app** (process enfant dans un PTY) : les fermer **tue**
le process. Voir `docs/SESSIONS.md`.

> Le dépôt s'appelle encore `claude-launcher/` (dossier historique) mais le produit,
> l'exécutable et l'app sont **`potof-toolkit`**.

## Commandes essentielles
```bash
swift build                            # compiler
swift run                              # lancer en dev (fenêtre au premier plan)
./Scripts/build-app.sh                 # packager + installer "Potof Toolkit.app" dans ~/Applications
./Scripts/build-app.sh /Applications   # variante (droits admin requis)
./Scripts/install-hook.sh              # (ré)installer le hook de notifs Claude (voir docs/NOTIFICATIONS.md)
```
Détails deploy / debug / données / permissions → **`docs/LIFECYCLE.md`**.

## Contraintes du projet (à respecter)
- macOS **13+**, `swift-tools-version:5.7`.
- **Une seule dépendance externe : SwiftTerm** (émulateur de terminal xterm, MIT),
  qui héberge les sessions `claude`. Ne pas en ajouter d'autres sans raison forte.
- **App Sandbox désactivée** — nécessaire pour lister des dossiers arbitraires ET pour
  qu'un sous-process lancé dans un PTY ait accès au disque/commandes. Ne PAS l'activer.
- Package **exécutable** buildable/lançable en terminal (sans Xcode).
- Structure volontairement simple, pas de MVVM lourd.

## Architecture (`Sources/potof-toolkit/`)
```
main.swift                    Entrée : NSApplication piloté à la main (pas de @main)
App/
  AppDelegate.swift           Fenêtre "Potof Toolkit", menu minimal, icône du Dock
  RootView.swift              Coquille : header = sélecteur d'outil (menu) + slot notif
Core/
  Tool.swift                  Abstraction d'un outil (id, title, subtitle, icon, view)
  ToolRegistry.swift          ⭐ Registre central = POINT D'EXTENSION UNIQUE
  Notifications/              Événements Claude branchés → docs/NOTIFICATIONS.md
    AppNotification.swift     Modèle d'event { sessionID?, kind, title, body, date }
    NotificationBus.swift     Bus de la cloche (ObservableObject) ; ingest(_:) = point d'entrée
    NotificationSlot.swift    Cloche + popover dans le header (lignes cliquables → focus)
    NotificationChannel.swift Tail du JSONL (DispatchSource vnode) ; décode ChannelEvent
    NotificationCenterCoordinator.swift  ⭐ Propriétaire : bus + Dock + bannières UN + clics
    NotificationSessionProviding.swift   Protocole de découplage (Core ↮ outil) + FocusRequest
Tools/
  ClaudeLauncher/             Premier outil
    ClaudeLauncherView.swift  UI : HSplitView(sidebar sessions+dossiers/favoris | terminal central)
    Session.swift             Modèle session possédée { id, folderURL, title, status }
    SessionStore.swift        Source de vérité UI : launch / close / focus
    TerminalController.swift  Possède les LocalProcessTerminalView (PTY), spawn/kill, délégué SwiftTerm
    TerminalHostView.swift    NSViewRepresentable : affiche la session active (vues gardées vivantes)
    FavoritesStore.swift      Favoris (chemins absolus, UserDefaults)
    FolderItem.swift          Modèle dossier (name + url)
Resources/AppIcon.png         Icône 1024×1024 (→ Bundle.module en dev, → .icns en bundle)
```
`Scripts/build-app.sh` : packaging en `.app` (voir LIFECYCLE). Détails du modèle de
session (spawn, PATH, cycle de vie) → **`docs/SESSIONS.md`**.

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
Rien d'autre à câbler : le **menu sélecteur d'outil** (dans le header) et le routage
sont automatiques. L'outil occupe tout le cadre sous le header et gère sa propre chrome.

## Invariants à NE PAS casser (et pourquoi)
- **`NSHostingController`** (jamais `NSHostingView`) comme `contentViewController` de la fenêtre
  → intégration correcte titlebar/toolbar de SwiftUI en hébergement manuel.
- **PAS de `NavigationSplitView`** pour la navigation racine. La sélection d'outil est un
  **menu dans une barre supérieure fixe** (le toggle auto de `NavigationSplitView` ne
  s'ancre pas dans une fenêtre hébergée manuellement et « saute »). Le split interne du
  Claude Launcher est un **`HSplitView`** (redimensionnable), c'est OK.
- **Focus fenêtre** : `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)`
  sont requis pour que la fenêtre s'affiche et prenne le focus via `swift run`.
- **Sessions = terminaux SwiftTerm possédés** : `TerminalController` possède un
  `LocalProcessTerminalView` par session, **conservé vivant** (jamais recréé au changement
  de session — sinon perte du process + scrollback). `TerminalHostView` ne fait que placer
  la vue. Toutes les mutations d'état passent par le **thread principal** (callbacks du
  delegate SwiftTerm remarshalés). Détails → `docs/SESSIONS.md`.
- **Login shell interactif pour le PATH** : on lance **`$SHELL -l -i`** (login + interactif
  → source `.zprofile`/`.zshrc`… → PATH complet), puis on écrit `cd '<dossier>' && claude⏎`.
  Ne PAS lancer `claude` en direct (le PATH par défaut de SwiftTerm exclut `PATH`).
  Échappement shell de l'apostrophe (`'` → `'\''`) conservé.
- **Quitter tue les sessions** (l'app possède les process) → `applicationShouldTerminate`
  confirme s'il reste des sessions actives. Garde-fou à conserver.
- **`POTOF_SESSION_ID`** injecté dans l'env de chaque session = clé de mapping des
  notifications. Le hook `~/.claude/hooks/claude-notify.js` append un JSONL dans
  `~/Library/Application Support/PotofToolkit/notifications.jsonl` quand cette variable est
  présente ; l'app le tail (`NotificationChannel`) et le `NotificationCenterCoordinator`
  alimente cloche + Dock + bannières natives. **Ne pas casser** ce contrat (nom de la
  variable, chemin du canal, forme des lignes). Détails → `docs/NOTIFICATIONS.md`.
- **Bannières natives gardées par `canUseUN`** (`Bundle.main.bundleURL.pathExtension == "app"`) :
  `UNUserNotificationCenter` crash sous `swift run` (pas de bundle). En dev, seules cloche +
  Dock marchent ; tester les bannières via l'app bundlée. Même logique que `applyDockIcon`.
- **Persistance** : `@AppStorage("rootPath")` et `UserDefaults` clé `claudeLauncher.favorites`.
  Stockage par domaine = bundle id → voir LIFECYCLE (dev et app bundlée = 2 stores). L'état
  des sessions n'est **jamais** persisté (reflète les process vivants).
- **Icône / `Bundle.module`** : `applyDockIcon()` pose l'icône du Dock via `Bundle.module`
  **uniquement en dev** (`swift run`, exécutable nu). En app bundlée (`.app`) il fait
  **l'impasse** (`guard Bundle.main.bundleURL.pathExtension != "app"`) : l'accessor SwiftPM
  résout le resource bundle à la **racine du `.app`** (hors structure signable, donc
  absent) et déclencherait un `fatalError` au démarrage. L'app bundlée tire son icône du
  `.icns` (Info.plist). ⚠️ Ne pas rappeler `Bundle.module` depuis un contexte bundlé, et
  garder le resource bundle dans `Contents/Resources/` (signable) dans `build-app.sh`.
