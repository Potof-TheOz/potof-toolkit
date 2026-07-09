# Notifications internes — câblage des événements Claude

Potof Toolkit reçoit les **événements Claude Code** de ses sessions embarquées et les
remonte sur **quatre surfaces** : la cloche du header, une **bannière macOS native**, le
**rebond** de l'icône du Dock et une **pastille** (badge) sur cette icône. Cliquer une
bannière ou une ligne de cloche ramène l'app au premier plan et **focalise** la session
concernée.

> Reprend la logique de l'ancienne intégration iTerm2 (`~/.claude/hooks/claude-notify.js`
> + `terminal-notifier`), mais en interne à l'app. 100 % local, aucun réseau (cf. CLAUDE.md).

## Chaîne complète

```
claude (session embarquée, env POTOF_SESSION_ID=<Session.id>)
   │  event Notification / Stop
   ▼
~/.claude/hooks/claude-notify.js   (hook Claude Code, events Notification + Stop)
   │  si POTOF_SESSION_ID présent → append JSONL (et saute terminal-notifier)
   ▼
~/Library/Application Support/PotofToolkit/notifications.jsonl
   │  { potofSessionId, event, notificationType, message, lastMessage, cwd, ts }
   ▼
NotificationChannel  (DispatchSource vnode, tail sur le thread principal)
   ▼
NotificationCenterCoordinator.shared
   ├─ bus.ingest(_:)                → cloche du header (NotificationSlot)
   ├─ NSApp.dockTile.badgeLabel     → pastille Dock
   ├─ NSApp.requestUserAttention    → rebond Dock
   └─ UNUserNotificationCenter.add  → bannière macOS (sauf anti-spam)

clic (bannière ou ligne de cloche)
   → NotificationCenterCoordinator.handleClick(sessionID:)
   → focusRequests (Combine) → RootView bascule l'outil affiché
   → SessionStore.focusSession(id) → session active au centre
```

## Côté hook — `~/.claude/hooks/claude-notify.js`

Le hook (branché sur les events `Notification` + `Stop` dans `~/.claude/settings.json`,
inchangé) lit le JSON de l'event sur stdin. **Quand `process.env.POTOF_SESSION_ID` est
présent** (session dans le terminal embarqué de l'app), il **append une ligne JSON** dans
le canal et **retourne sans lancer `terminal-notifier`** (l'app pose sa propre bannière →
pas de double bannière) :

```js
const potofSid = process.env.POTOF_SESSION_ID;
if (potofSid) {
  appendPotofChannel({ potofSessionId: potofSid, event, message, cwd, ts: Date.now() });
  return;
}
// … sinon : chemin ITERM_SESSION_ID + terminal-notifier INCHANGÉ (iTerm2, etc.) …
```

`appendFileSync` (`O_APPEND`) → chaque ligne JSON est écrite atomiquement. `ts` en **ms**.

### Source de vérité & (ré)installation

Le hook est un fichier **global** (`~/.claude/hooks/claude-notify.js`) qui notifie **toutes**
tes sessions Claude, y compris hors Potof Toolkit (iTerm2 → `terminal-notifier`). Il n'est
donc **pas** à sa place canonique dans le repo, mais on en garde une **copie versionnée**
(`hooks/claude-notify.js`) pour ne pas le perdre et pouvoir le réinstaller ailleurs.

Pour (ré)installer sur cette machine ou un autre poste :

```bash
./Scripts/install-hook.sh
```

Le script copie `hooks/claude-notify.js` → `~/.claude/hooks/`, le rend exécutable, et câble
(idempotent, avec backup) les events `Notification` + `Stop` dans `~/.claude/settings.json`.
⚠️ Après toute modif du hook, mettre à jour la copie du repo (`cp ~/.claude/hooks/claude-notify.js
hooks/claude-notify.js`) — le repo reste la source de vérité.

## Côté app — les fichiers

| Fichier | Rôle |
|---|---|
| `TerminalController.start` | injecte `POTOF_SESSION_ID=<Session.id>` dans l'env de chaque session |
| `Core/Notifications/NotificationChannel.swift` | tail le JSONL via `DispatchSource` vnode ; décode chaque ligne (`ChannelEvent`) sur `main` |
| `Core/Notifications/NotificationCenterCoordinator.swift` | **propriétaire unique** : possède le `NotificationBus`, la Dock tile, le délégué `UNUserNotificationCenter` ; pipeline par event + routage des clics |
| `Core/Notifications/NotificationSessionProviding.swift` | protocole de découplage (`Core` ne connaît pas l'outil) + `FocusRequest` |
| `Core/Notifications/AppNotification.swift` | modèle d'event `{ sessionID?, kind(.waiting/.finished), title, body, date }` |
| `Core/Notifications/NotificationBus.swift` | bus de la cloche (`ingest` / `dismiss` / `clear`) |
| `Core/Notifications/NotificationSlot.swift` | cloche + popover ; lignes cliquables (`onSelect`) + `onReveal` |
| `SessionStore` (extension) | conforme `NotificationSessionProviding` ; `containsSession` / `activeSessionID` / `focusSession` |

### Le pont entre les deux arbres de vues

Le `NotificationBus`, la `selection` d'outil et la Dock tile vivent au **niveau app**
(`RootView` / `AppDelegate`) ; le `SessionStore` vit **dans l'outil** ClaudeLauncher. Le
coordinateur (singleton, comme `TerminalController.shared`) les relie via **deux coutures
découplées** :

- **`NotificationSessionProviding`** (outil → Core) : `ClaudeLauncherView` enregistre son
  `SessionStore` auprès du coordinateur (`registerSessionProvider(_:toolID:)`) en fournissant
  son `Tool.ID`. `Core` n'importe jamais l'outil et ne code aucun id en dur.
- **`focusRequests` (Combine `PassthroughSubject`)** (Core → RootView) : au clic, le
  coordinateur émet un `FocusRequest` ; `RootView` s'y abonne (`.onReceive`) et reste **le
  seul writer** de `selection` (invariant : sélection d'outil = menu du header).

### Trois types d'événement (`AppNotification.Kind`)

| Situation | Détection | Rendu |
|---|---|---|
| **Action attendue** (TUI bloquée) | `Notification` + `notification_type == "permission_prompt"` | 🔔 « Claude attend ton action » (`bell.badge`, bleu) |
| **Question / attente réponse** | `Notification` `idle_prompt`/`agent_needs_input`, **ou** `Stop` dont `last_assistant_message` finit par « ? » | 💬 « Claude attend une réponse » (`bubble.left`, orange) |
| **Tâche terminée** | event `Stop` (message qui n'est pas une question) | ✅ « Claude a terminé » (coche, vert) |

⚠️ Deux limites de Claude Code (constatées en v2.1.205, via dump des payloads) :
- **`permission_prompt` est ambigu** : il est émis à l'identique (`message: "Claude needs
  your permission"`, aucun champ outil/`details`) aussi bien pour une **approbation d'outil**
  que pour une **question interactive à choix multiple** (`AskUserQuestion`). Impossible de
  les distinguer → un **seul** libellé neutre (« attend ton action »).
- **Une question de fin de tour arrive comme un `Stop`** (aucun `idle_prompt` émis dans ce
  flux). D'où l'heuristique `isQuestion` sur `last_assistant_message` (finit par « ? ») pour
  séparer question et tâche terminée. Le corps de la notif reprend le message, tronqué ~140 car.

### Anti-spam

Pas de **bannière** si `NSApp.isActive && activeSessionID == sessionID` (on regarde déjà
cette session). Version in-process triviale — pas d'AppleScript (contrairement à l'ancien
hook iTerm2). La **cloche** enregistre quand même l'event.

### Cycle de vie & robustesse

- `AppDelegate.applicationDidFinishLaunching` → `NotificationCenterCoordinator.shared.start()` ;
  `applicationWillTerminate` → `stop()`.
- **Truncate au lancement** : le canal est vidé au démarrage de l'app (les vieilles lignes
  réfèrent des sessions mortes — jamais persistées ; les rejouer serait faux) et sa taille
  reste bornée.
- Le tailer gère troncature/rotation (`offset > taille` → reset) et suppression/renommage du
  fichier (`.delete`/`.rename` → ré-arme, avec debounce).

## Caveat de test — bannières natives

`UNUserNotificationCenter.current()` exige un **vrai bundle** (lit `bundleProxyForCurrentProcess`) :
sous `swift run` (exécutable nu) il crasherait. Tout le code UN est donc gardé par
`canUseUN = (Bundle.main.bundleURL.pathExtension == "app")` (même style que
`AppDelegate.applyDockIcon`).

- **`swift run`** : cloche + pastille + rebond Dock fonctionnent ; **bannières ignorées**.
- **`.app` bundlée** (`./Scripts/build-app.sh` puis lancer l'app installée) : bannières
  natives actives. Premier lancement = **prompt d'autorisation** macOS ; si refusé, pas de
  bannière (cloche/Dock OK). Rappel machine : Réglages → Notifications → « Autoriser quand
  l'écran est partagé/dupliqué », sinon les bannières sont masquées.
