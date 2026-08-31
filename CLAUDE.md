# Potof Toolkit

App macOS native (SwiftUI + AppKit) servant de **toolkit d'outils de dev locaux**.
**Local par défaut** : aucun compte, aucune télémétrie, aucune sortie réseau — à une
exception **opt-in** près, la génération de message de commit de Git Stuffs, qui invoque
`claude` (outil externe → réseau) et, depuis le Superset Scheduler, l'appel à la CLI `superset`
(qui parle au host service en **loopback** et fait spawner des agents `claude` → réseau).
Seule écoute : un socket **`127.0.0.1` uniquement**
(pont IDE, cf. plus bas), protégé par un token. Quatre outils à ce jour :
**Claude Launcher** — liste les sous-dossiers d'un dossier racine et lance `claude`
dans un **terminal embarqué** (SwiftTerm) affiché **au centre de l'app** ; les
sessions sont **possédées par l'app** (process enfant dans un PTY) : les fermer
**tue** le process (voir `docs/SESSIONS.md`). **Git Stuffs** — explore les repos git
du poste, **rebase interactivement** et **édite la copie de travail** (staging par
hunk/ligne, commit, push/pull avec badge ahead/behind, résolution de conflits dans
l'app). **Script Runner** — découvre les `package.json`
et lance/arrête leurs scripts npm sur le même modèle de terminal possédé
(voir `docs/SCRIPT_RUNNER.md`). **Superset Scheduler** — écrit et entretient un **job launchd**
par planification, qui rappelle le binaire de l'app en **mode headless**
(`--run-schedule <uuid>`) pour lancer un agent Superset à heure fixe ; l'outil garantit le
**lancement**, jamais le résultat (voir `docs/SCHEDULER.md`).
Transversal aux outils : le **pont IDE** — l'app se fait passer pour un IDE Claude Code
et **valide dans une fenêtre flottante** les modifications proposées par les agents
`claude` du poste (Superset, terminaux, sessions embarquées) au lieu du prompt de
permission du terminal (voir `docs/IDE_BRIDGE.md`).

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
  AppDelegate.swift           Fenêtre "Potof Toolkit", menus (dont « Hôte IDE »), icône du Dock,
                              démarrage/arrêt de l'hôte IDE + du canal de notifications
  RootView.swift              Coquille : DEUX états — home (aucun outil choisi, sans header)
                              | header (sélecteur d'outil + slot notif) + outil
  HomeView.swift              ⭐ Landing page du LANCEMENT : grille des cartes d'outils issue de
                              ToolRegistry (+ ⌘1…⌘9). Aller-simple : on n'y revient jamais
  CLIHelp.swift               `--help`/`-h` en 1ʳᵉ position + texte d'usage. PUR (pas d'AppKit) pour
                              être testable sans démarrer le binaire → docs/SCHEDULER.md, « Débogage »
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
  IDEHost/                    Pont IDE : l'app se fait passer pour un IDE Claude Code et sert des
                              agents EXTERNES (Superset, terminaux) → docs/IDE_BRIDGE.md
    IDEProtocolContract.swift ⭐ LE contrat en un seul endroit : formes de réponse openDiff, noms
                              d'outils, en-tête d'auth, dernière version de claude validée
    IDEBridge.swift           Types (IDEDiffRequest/Verdict, IDEDiffHandlers) + logger IDELog
    IDEHost.swift             ⭐ Hôte GLOBAL (singleton) : 1 port, 1 lock ($HOME), N connexions
    IDEServer.swift           Serveur d'UNE session possédée (port injecté) + sweepStaleLocks
    IDEConnection.swift       Handshake WebSocket + framing RFC 6455 + JSON-RPC/MCP, N openDiff en vol
    IDEClientIdentity.swift   pid (ide_connected) → cwd (lsof) → worktree → « Superset · branche »
    IDEContractGuard.swift    ⭐ Vérif post-acceptation + empreinte de version + bandeau de dérive
    IDEHostSettings.swift     Périmètre servi (ideHost.scope) / activation à la réception / expiration
    IDEHostMenu.swift         Menu « Hôte IDE » de la barre de menus (périmètre + diagnostic)
    IDEHostStatusView.swift   Panneau de diagnostic (port, périmètre, clients) — lecture seule
  DiffReview/                 Surface de validation UNIQUE, toutes origines confondues
    DiffReviewCenter.swift    ⭐ Singleton : file d'attente des demandes + résolution (verdict)
    DiffReviewWindow.swift    NSPanel flottant (NSHostingController) + bannières + cycle de vie
    DiffReviewView.swift      Corps : en-tête agent/fichier, unifié | côte à côte | édition, actions
    DiffEditorView.swift      NSTextView monospace : amender le contenu avant de l'accepter
  Diff/                       Moteur de diff PARTAGÉ (aucun lien avec git ni avec le pont IDE)
    DiffModel.swift           DiffComputer / FileDiff / DiffLine (rognage préfixe/suffixe + LCS)
    DiffLineRow.swift         Rendu d'une ligne (unifié) — revue des diffs + CommitDiffView
    DiffHalfRow.swift         Demi-ligne (côte à côte) ; SideBySideDiff.swift apparie les lignes
    DiffLayoutMode.swift      Enum unifié/côte à côte + DiffLayoutToggle (bascule façon WebStorm)
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
                              (le pont IDE a quitté ce dossier → Core/IDEHost/)
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
  Scheduler/                  Quatrième outil : agents Superset à heure fixe → docs/SCHEDULER.md
    Schedule.swift            ⭐ Modèles : Schedule + Action/Recurrence/Target (Codable À LA MAIN,
                              discriminant "kind") + validate() + nommage gelé des workspaces neufs
    ScheduleRun.swift         RunStatus (⭐ `launched`, pas `ok`) / RunLine / RunRecord.fold (PUR)
    SchedulePaths.swift       ⭐ Tous les chemins + overrideRoot (probes sans effet de bord) +
                              canInstallLaunchAgents + résolution du shim `superset`
    SupersetCLI.swift         Shell-out CLI (gabarit Git.swift) + timeout + nettoyage d'env + JSON
    AgentPresence.swift       « un agent claude vit-il dans ce worktree ? » (pgrep → lsof cwd)
    LaunchAgentPlist.swift    Recurrence → StartCalendarInterval + génération du .plist (PUR)
    SchedulerService.swift    bootout/enable/bootstrap + audit/repair + règle des DEUX conditions
    ScheduleStore.swift       ⭐ Singleton : SEUL écrivain de schedules.json + tail du JSONL
    RunLog.swift              JSONL append-only sous flock + compaction EN PLACE (jamais rename)
    ScheduleRunner.swift      ⭐ Mode headless (`Foundation` SEUL) : la séquence et les garde-fous
    ScheduleNotifier.swift    Bannière système du runner (UserNotifications, PAS osascript)
    SchedulerSelfTest.swift   Dispatcher `--sched-selftest cli|plist|store|run` (figé)
    ScheduleStoreProbe.swift / ScheduleRunnerProbe.swift   Auto-tests des lots correspondants
    UI/SchedulerView.swift    HSplitView(liste | détail) + bandeaux audit/dev ; formulaire EN PLACE
    UI/ScheduleRunHistoryView.swift  Historique alimenté par le tail (runs d'un autre process inclus)
    UI/ScheduleFormView.swift / RecurrencePicker.swift / TargetPicker.swift   Formulaire et sélecteurs
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
Rien d'autre à câbler : la **carte sur la home** (avec son raccourci ⌘N), le **menu
sélecteur d'outil** (dans le header) et le routage sont automatiques — tous les trois
itèrent `ToolRegistry.all`, il n'y a **aucune liste d'outils à maintenir en double**.
L'outil occupe tout le cadre sous le header et gère sa propre chrome.

## Invariants à NE PAS casser (et pourquoi)
- **`NSHostingController`** (jamais `NSHostingView`) comme `contentViewController` de la fenêtre
  → intégration correcte titlebar/toolbar de SwiftUI en hébergement manuel.
- **PAS de `NavigationSplitView`** pour la navigation racine. La sélection d'outil est un
  **menu dans une barre supérieure fixe** (le toggle auto de `NavigationSplitView` ne
  s'ancre pas dans une fenêtre hébergée manuellement et « saute »). Le split interne du
  Claude Launcher est un **`HSplitView`** (redimensionnable), c'est OK.
- **La home est un ALLER-SIMPLE, visible au seul lancement** : `RootView` démarre avec
  `selection == nil` → `HomeView` occupe toute la fenêtre, **sans header** (un sélecteur
  d'outils au-dessus d'une grille d'outils ferait doublon). **Aucun chemin ne remet
  `selection` à `nil`** : pas de bouton « accueil », pas d'entrée de menu. En ajouter un
  ne romprait pas que la promesse produit — `.id(tool.id)` **détruirait l'outil quitté**
  (et ses `@StateObject`), donc tout état non porté par un singleton app-level. La grille
  se remplit seule depuis `ToolRegistry`.
- **Focus fenêtre** : `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)`
  sont requis pour que la fenêtre s'affiche et prenne le focus via `swift run`.
- **Sessions = terminaux SwiftTerm possédés** : `TerminalController` possède un
  `LocalProcessTerminalView` par session, **conservé vivant** (jamais recréé au changement
  de session — sinon perte du process + scrollback). `TerminalHostView` ne fait que placer
  la vue. Toutes les mutations d'état passent par le **thread principal** (callbacks du
  delegate SwiftTerm remarshalés). Détails → `docs/SESSIONS.md`.
- **Changer d'outil ne perd jamais un terminal** : `RootView` pose `.id(tool.id)` sur la
  vue de l'outil → au switch, la vue ET ses `@StateObject` sont **détruits**. Tout état
  process-backed **ou connexion-backed** vit donc dans des **singletons app-level**
  (`SessionStore.shared`, `ScriptRunStore.shared` et leurs contrôleurs terminal ;
  `IDEHost.shared`, `DiffReviewCenter.shared`, `IDEContractGuard.shared` pour le pont
  IDE), observés via `@ObservedObject`.
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
- **Persistance** : `@AppStorage("rootPath")` et `UserDefaults` clés `claudeLauncher.favorites`,
  `scriptRunner.packageDirs`, `ideHost.*` (périmètre de l'hôte IDE), `diffReview.layoutMode`.
  ⚠️ **Exception : le Superset Scheduler persiste en FICHIERS, pas en `UserDefaults`** — c'est le
  premier format d'**écriture** `Codable` de l'app (la lecture existait déjà :
  `PreviousSessionsStore`, `NotificationChannel`). Raison : `UserDefaults` ne notifie pas de
  façon fiable les écritures d'un **autre process**, or le mode headless en est un.
  Stockage par domaine = bundle id → voir LIFECYCLE (dev et app bundlée = 2 stores). L'état
  des sessions, des runs et des **demandes de revue** n'est **jamais** persisté (il reflète
  des process et des connexions vivants).
- **Icône / `Bundle.module`** : `applyDockIcon()` pose l'icône du Dock via `Bundle.module`
  **uniquement en dev** (`swift run`, exécutable nu). En app bundlée (`.app`) il fait
  **l'impasse** (`guard Bundle.main.bundleURL.pathExtension != "app"`) : l'accessor SwiftPM
  résout le resource bundle à la **racine du `.app`** (hors structure signable, donc
  absent) et déclencherait un `fatalError` au démarrage. L'app bundlée tire son icône du
  `.icns` (Info.plist). ⚠️ Ne pas rappeler `Bundle.module` depuis un contexte bundlé, et
  garder le resource bundle dans `Contents/Resources/` (signable) dans `build-app.sh`.
- **Superset Scheduler : le mode headless est un AUTRE process, et c'est tout le sujet**
  (détails → `docs/SCHEDULER.md`). launchd rappelle le binaire de l'app en
  `--run-schedule <uuid>`, **avant `NSApplication`** (même emplacement que `--ide-selftest`
  dans `main.swift`). Sept points à ne pas casser :
  1. **`ScheduleRunner` n'importe que `Foundation`.** Garantie structurelle, pas convention :
     avec ce seul import, `NSApp` devient une erreur de compilation. Et il ne réveille
     **aucun** singleton — le plus vicieux étant `NotificationCenterCoordinator.shared`,
     dont le `start()` fait `open(…, O_TRUNC)` sur `notifications.jsonl` et **effacerait le
     canal de la GUI en cours d'exécution**. `IDEHost.shared` prendrait le lock `$HOME` et
     tuerait l'auto-connexion des deux côtés. D'où le passage par le **statique**
     `ScheduleStore.loadFromDisk()`, qui n'instancie rien.
  2. **`schedules.json` a un seul écrivain : la GUI.** Le headless est lecteur seul, et
     unique écrivain de sa portion du JSONL. Corollaire : **pas de `lastRunAt` dans
     `Schedule`**, il est dérivé de `runs.jsonl`. Ne pas « améliorer » ça.
  3. **`launched`, jamais `ok`.** Le runner sait seulement que `agents create` a rendu 0. Un
     historique tout vert ne prouve que la mise à feu. Et `skipped` (garde-fou qui a joué)
     reste distinct de `failed`.
  4. **Compaction du JSONL EN PLACE** (`ftruncate`), **jamais par `rename`** : ça changerait
     l'inode sous le nez d'un appender ayant déjà son `fd` ouvert.
  5. **Écriture dans `~/Library/LaunchAgents` : les DEUX conditions**, nom
     `com.potof.toolkit.schedule.<uuid>.plist` **ET** `ProgramArguments[0]` finissant par
     `/potof-toolkit`. **Jamais de suppression par glob** — ce dossier exécute du code
     arbitraire à l'ouverture de session.
  6. **`StartCalendarInterval` : jamais `StartInterval`, `RunAtLoad = false`, pas de
     `KeepAlive`, jamais de `Weekday` dans un mensuel** (`Day` + `Weekday` est un OU), et
     **jamais de dictionnaire vide** (il vaut « toutes les minutes »). Cadences bornées aux
     diviseurs de 24 et aux jours 1…28 (launchd ne clampe pas).
  7. **Pas de `launchctl kickstart`, et `runNow` est le SEUL chemin de l'UI vers un run
     réel.** Le kickstart a existé derrière un bouton « Tester le déclencheur » présenté
     comme un diagnostic : il lançait un run complet (le plist fige son argv **sans**
     `--dry-run`, donc launchd ne sait pas simuler) et a créé deux agents payants en trois
     clics. Supprimé, pas renommé — même geste que `confirmEditInTerminal` côté pont IDE.
     La simulation est en-process : `ScheduleRunner.executeReporting(…, dryRun: true)`,
     bouton « Simuler » → onglet « Plan ».

  ⚠️ `canInstallLaunchAgents` (= `pathExtension == "app"`, même garde que `canUseUN`)
  **interdit d'installer depuis `swift run`** : le chemin `.build/debug/` est éphémère, un
  plist pointant là serait mort au premier `swift package clean`, sans le moindre signal.
- **Pont IDE : le panneau de diff EST le prompt de permission** (détails →
  `docs/IDE_BRIDGE.md`). L'app se fait passer pour un IDE Claude Code (serveur MCP
  WebSocket, framing RFC 6455 fait main via `Network.framework` — pas de dépendance
  ajoutée). **Contrat non-officiel, re-vérifié dans le binaire `claude 2.1.220`** ; il
  a déjà dérivé une fois en silence. Les cinq points à ne pas casser :
  1. **La réponse `FILE_SAVED` porte DEUX blocs** —
     `[{text:"FILE_SAVED"}, {text:"<contenu final>"}]`. Le CLI teste
     `typeof content[1].text === "string"` : à un seul bloc il part en `TypeError`,
     l'édition n'est **jamais** appliquée, et personne ne le voit. Passer
     exclusivement par `IDEProtocolContract.acceptedContent`. Le 2ᵉ bloc **devient
     l'input réel** de l'outil `Edit`/`Write` → accepter en amendant est légitime ;
     renvoyer un contenu identique au disque équivaut à un **refus**.
  2. **Ne JAMAIS taper `Entrée` à l'aveugle dans un terminal.** Quand la réponse est
     bien formée, `openDiff` rend un `allow`/`deny` et **aucun prompt n'apparaît**.
     L'ancien `confirmEditInTerminal` (repli aveugle à 6 s) est supprimé : réintroduit,
     il validerait n'importe quel prompt présent à cet instant. Il ne reste qu'une
     surveillance **conditionnelle** qui lève le bandeau de dérive.
  3. **L'app n'écrit JAMAIS sur disque** — elle ne produit qu'un verdict, c'est
     `claude` qui applique. `IDEContractGuard` relit le fichier (≤ 3 s) après une
     acceptation : c'est le seul signal qui ne suppose rien du protocole.
  4. **Un lock global (`IDEHost`) sert tout `$HOME`** ; les sessions possédées gardent
     leur `IDEServer` par session (port injecté = routage exact). Le matching côté
     `claude` est **par préfixe de chemin**, et il ne s'auto-connecte que s'il trouve
     **exactement un** IDE valide : un autre IDE actif sur le même arbre (WebStorm,
     VS Code…) — ou une 2ᵉ instance de Potof lancée pour un test — **neutralise
     l'auto-connexion des deux côtés**. Réglage de périmètre : menu « Hôte IDE ».
  5. **La surface de validation est UNIQUE** : `DiffReviewCenter` (file d'attente
     app-level, singleton) + la **fenêtre flottante** `DiffReviewWindow`. Plus d'aperçu
     in situ à la place du terminal. Ne **jamais** supposer un seul `openDiff` en vol
     ni un seul agent : les sous-agents `Task` en émettent en parallèle, l'appel est
     **bloquant**, et une demande sans réponse fige un agent indéfiniment.

  ⚠️ **Ne PAS lancer `claude` en `--permission-mode acceptEdits`** ni en
  `--dangerously-skip-permissions` : sans demande de permission, plus aucun `openDiff`.
  Le pont ne couvre de toute façon que `Edit`/`Write` (ni Bash, ni notebooks, ni outils
  MCP). `POTOF_SESSION_ID` reste la clé notifs, distincte du pont.
