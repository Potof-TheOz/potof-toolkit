# Potof Toolkit

App macOS native (SwiftUI + AppKit) servant de **toolkit d'outils de dev locaux**.
**Local par défaut** : aucun compte, aucune télémétrie, pas de réseau — à une exception
**opt-in** près, la génération de message de commit de Git Stuffs, qui invoque `claude`
(outil externe → réseau). Trois outils à ce jour :
**Claude Launcher** — liste les sous-dossiers d'un dossier racine et lance `claude`
dans un **terminal embarqué** (SwiftTerm) affiché **au centre de l'app** ; les
sessions sont **possédées par l'app** (process enfant dans un PTY) : les fermer
**tue** le process (voir `docs/SESSIONS.md`). **Git Stuffs** — explore les repos git
du poste, **rebase interactivement** et **édite la copie de travail** (staging par
hunk/ligne, commit, push/pull avec badge ahead/behind, résolution de conflits dans
l'app). **Script Runner** — découvre les `package.json`
et lance/arrête leurs scripts npm sur le même modèle de terminal possédé
(voir `docs/SCRIPT_RUNNER.md`).

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
- **PAS de build/déploiement « sauvage » dans `~/Applications`** (ni `rm -rf` /
  remplacement du bundle installé, ni quitter/relancer l'instance en cours) **sans
  demande explicite de l'utilisateur** — ça tuerait toute session Claude embarquée.
  **Si on n'est pas sur `main`, on ne déploie jamais dans `~/Applications`.** Pour
  tester : **packager dans le scratchpad** (bundle `.app` assemblé hors `~/Applications`),
  **sans toucher l'instance en cours** et **sans enregistrer le bundle dans Launch
  Services** (`lsregister`) — pour ne pas détourner l'`open -a "Potof Toolkit"` habituel.
  Lancer l'instance de test par chemin explicite : `open -n "<scratchpad>/Potof Toolkit.app"`.

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
  Terminal/
    TerminalHostView.swift    NSViewRepresentable partagé (a quitté ClaudeLauncher/) : place la
                              vue terminal possédée par le contrôleur appelant + focus au chgt d'id
  FileTree/                   Arbre de fichiers GÉNÉRIQUE (aucune dépendance git), réutilisable
    FileTreeModel.swift       FileTreeItem/Node + FileTreeBuilder (build + compaction dossiers + flatten)
    FileTreeView.swift        Vue générique : slots onSelect/leading/trailing ; pliage détenu par
                              l'appelant (@Binding) ; identité des lignes + clé de pliage NAMESPACÉES
Tools/
  ClaudeLauncher/             Premier outil
    ClaudeLauncherView.swift  UI : HSplitView(sidebar sessions+dossiers/favoris | terminal central)
    Session.swift             Modèle session possédée { id, folderURL, title, status }
    SessionStore.swift        ⭐ Singleton : launch / close / focus (survit au switch d'outil)
    TerminalController.swift  Possède les LocalProcessTerminalView (PTY), spawn/kill, délégué SwiftTerm
    FavoritesStore.swift      Favoris (chemins absolus, UserDefaults)
    FolderItem.swift          Modèle dossier (name + url)
    IDE/                      Pont IDE : aperçu des diffs Claude → docs/IDE_BRIDGE.md
      IDEBridge.swift         Types (IDEDiffRequest/Verdict, IDEDiffHandlers) + logger IDELog
      IDEServer.swift         Serveur MCP WebSocket + lock file ~/.claude/ide (1 par session)
      IDEConnection.swift     Handshake WebSocket + framing RFC 6455 + JSON-RPC/MCP (openDiff)
      DiffModel.swift         Diff ligne-à-ligne (rognage préfixe/suffixe + LCS + garde-fou)
      DiffOverlayView.swift   Panneau SwiftUI : diff unifié + Accepter/Refuser
  GitStuffs/                  Deuxième outil : explorer les repos git, rebase interactif + copie de travail
    GitStuffsView.swift       UI racine : sélection d'un worktree (favoris de projets) + fallback + onboarding
    Projects/                 ⭐ Favoris de PROJETS worktree-aware (unité = --git-common-dir, pas un dossier de repo)
      GitProjectModels.swift  Worktree/GitProject + parsers PURS (git worktree list ; .git worktree vs sous-module)
      GitProjectService.swift Shell-outs git fins : common-dir absolu normalisé, worktree list, resolveProject
      ProjectStore.swift      ⭐ Store : scan (accepte les .git FICHIERS, saute les sous-modules) + favoris + dernier
                              worktree ouvert + worktrees énumérés PARESSEUSEMENT ; NON process-backed (@StateObject)
      ProjectPicker.swift     Sélecteur de PROJET : 2 sections (Favoris + Tous repliée) / recherche plate / ★ / Ajouter
      WorktreePicker.swift    Sélecteur de WORKTREE (branche) du projet courant : dropdown si multi, libellé sinon
    RepoDetailView.swift      ⭐ Espace de travail (modèle GitHub Desktop) : top bar (ProjectPicker + WorktreePicker +
                              sync ↑/↓/⚠️ + Fetch/Pull/Push) + onglets Modifications | Historique. Alimenté par worktree.url.
    CommitDiffView.swift      Diff LECTURE SEULE d'un commit (arbre de fichiers + git show)
    WorkingCopy/              Couche « copie de travail » : staging hunk/ligne, commit, sync, conflits
      GitStatusModels.swift   FileStatus, RepoSyncState, protocole WorkingCopyServicing (contrat des actions)
      GitStatusParser.swift   Porcelain v2 -z → [FileStatus] + ahead/behind (fonctions PURES, testables)
      UnifiedDiff.swift       Parseur diff unifié + buildPatch(selecting:) : staging par ligne BYTE-EXACT
      GitWorkingActions.swift Impl. WorkingCopyServicing : add/restore/commit/push/pull/fetch/apply
      WorkingCopyStore.swift  ⭐ ObservableObject : statut + RepoSyncState + timer fetch (~3 min) + refresh
      ChangesListView.swift   Colonne gauche : sections Conflits/Indexé/Non indexé + boîte de commit (✨ Générer)
      WorkingDiffView.swift   Diff INTERACTIF : cases hunk/ligne, stager/jeter la sélection, bascule staged
      Conflict/               Résolution de conflits DANS l'app (rebase OU merge en pause)
        ConflictModels.swift        Parse marqueurs <<<<<<< ======= >>>>>>> → régions { ours, theirs }
        ConflictResolver.swift      Applique les choix, réécrit le fichier, git add, continue/abort
        ConflictResolutionView.swift UI de résolution bloc-par-bloc (nôtre/leur/les deux) + édition libre
  ScriptRunner/               Troisième outil : scripts npm → docs/SCRIPT_RUNNER.md
    PackageProject.swift      Modèles ScriptPackage (id = chemin) + PackageProject { root, subpackages }
    PackageStore.swift        Scan $HOME en fond + groupage monorepo + cache chemins (scriptRunner.packageDirs)
    PackageManifest.swift     Relecture à chaud de package.json { name?, scripts triés par nom }
    PackageManager.swift      npm/pnpm/yarn/bun : détection par lockfile racine + runCommand échappé
    ScriptRun.swift           Modèle run { id, packageDir, scriptName, status } + decodeWaitStatus(raw)
    ScriptTerminalController.swift  Possède les LocalProcessTerminalView (1/run), spawn + primitives d'arrêt
    ScriptRunStore.swift      ⭐ Singleton : launch/stop/close/focus + machine à états de l'arrêt
    ScriptRunnerView.swift    UI : HSplitView(sidebar exécutions+projets | run ou détail au centre)
    PackageDetailView.swift   Détail d'un package : scripts + badge manager + ▶ (ou « voir le run »)
Resources/AppIcon.png         Icône 1024×1024 (→ Bundle.module en dev, → .icns en bundle)
```
`Scripts/build-app.sh` : packaging en `.app` (voir LIFECYCLE). Détails du modèle de
session (spawn, PATH, cycle de vie) → **`docs/SESSIONS.md`** ; modèle d'exécution et
d'arrêt des scripts npm → **`docs/SCRIPT_RUNNER.md`**.

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
- **Changer d'outil ne perd jamais un terminal** : `RootView` pose `.id(tool.id)` sur la
  vue de l'outil → au switch, la vue ET ses `@StateObject` sont **détruits**. Tout état
  process-backed vit donc dans des **singletons app-level** (`SessionStore.shared`,
  `ScriptRunStore.shared` et leurs contrôleurs terminal), observés via `@ObservedObject`.
  Ne PAS revenir à des `@StateObject` pour ces stores (sinon terminaux orphelins :
  process vivants mais invisibles au retour sur l'outil).
- **Login shell interactif pour le PATH** : on lance **`$SHELL -l -i`** (login + interactif
  → source `.zprofile`/`.zshrc`… → PATH complet), puis on écrit `cd '<dossier>' && claude⏎`.
  Ne PAS lancer `claude` en direct (le PATH par défaut de SwiftTerm exclut `PATH`).
  Échappement shell de l'apostrophe (`'` → `'\''`) conservé.
- **Script Runner : contrat `; exit` + statut waitpid brut** : la commande écrite est
  `cd '<dir>' && <mgr> run '<script>'; exit` — `; exit` (PAS `&&`) fait mourir le shell
  même si le script échoue, et `exit` sans argument propage `$?` → la fin du script tue
  le shell et `processTerminated` livre alors le statut waitpid **BRUT** (exit 1 arrive
  comme `256`), à décoder exclusivement via `ScriptRun.decodeWaitStatus`. Détails →
  `docs/SCRIPT_RUNNER.md`.
- **Kill propre des scripts** : ne JAMAIS utiliser `terminate()` de SwiftTerm pour arrêter
  un run (il annule le monitor d'exit → plus aucun callback, badge figé) ; l'arrêt est la
  séquence graduée Ctrl-C → `exit\r` conditionné par `tcgetpgrp(childfd) == shellPid`
  (shell revenu au prompt) → SIGKILL du groupe de premier plan + du shell (~3 s).
  `terminate()` ne sert qu'à **libérer** une vue. Détails → `docs/SCRIPT_RUNNER.md`.
- **Quitter tue les sessions et les runs de scripts** (l'app possède les process) →
  `applicationShouldTerminate` confirme s'il reste des process actifs (alerte combinée
  sessions Claude + scripts) et `applicationWillTerminate` hardKill les groupes des
  scripts. Garde-fou à conserver.
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
- **Pont IDE = aperçu des diffs, PAS l'écriture** (détails → `docs/IDE_BRIDGE.md`).
  `TerminalController` ouvre un serveur MCP WebSocket par session et injecte
  `CLAUDE_CODE_SSE_PORT` + `ENABLE_IDE_INTEGRATION` → `claude` route ses éditions via
  l'outil `openDiff`. **Contrat non-officiel, vérifié empiriquement** (framing WebSocket
  fait main via `Network.framework` — pas de dépendance ajoutée). Deux pièges à retenir :
  (1) `openDiff` n'est qu'un **aperçu** ; en mode permission par défaut l'approbation
  réelle est un **prompt de permission dans le terminal** → « Accepter » renvoie
  `FILE_SAVED` **puis** répond « Yes » au prompt (`SessionStore.confirmEditInTerminal`).
  (2) **Ne PAS lancer `claude` en `--permission-mode acceptEdits`** (Claude n'appelle
  alors plus `openDiff` → plus d'aperçu). Le panneau **remplace** le terminal (pas un
  overlay : au-dessus du `NSView` SwiftTerm, un overlay SwiftUI ne capte pas les clics).
  L'app **n'écrit jamais** sur disque. `POTOF_SESSION_ID` reste la clé notifs, distincte.
