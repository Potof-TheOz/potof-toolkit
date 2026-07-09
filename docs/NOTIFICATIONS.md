# Notifications internes — plan de câblage (ancrages en place, non branché)

Objectif à terme : une **barre de notif interne** à Potof Toolkit, alimentée par le
système de notif Claude déjà en place, avec clic → focus de la session concernée.

**État actuel : ancrages seulement.** Le code prévoit les points d'accroche mais
**aucun canal n'est branché** — la cloche du header reste vide.

## Ce qui est déjà en place (ancrages)

| Élément | Fichier | Rôle |
|---|---|---|
| `POTOF_SESSION_ID` | `TerminalController.start` | chaque session `claude` reçoit un id unique dans son env |
| `AppNotification` | `Core/Notifications/AppNotification.swift` | modèle d'event `{ sessionID?, kind, title, body, date }` |
| `NotificationBus` | `Core/Notifications/NotificationBus.swift` | bus interne ; **`ingest(_:)`** = point d'entrée unique |
| `NotificationSlot` | `Core/Notifications/NotificationSlot.swift` | cloche + popover dans le header (`RootView`) |

Brancher la notif = **faire appeler `NotificationBus.ingest(_:)`** depuis un lecteur
de canal, sur le thread principal. Rien d'autre côté UI.

## Le système de notif existant (rappel)

`~/.claude/hooks/claude-notify.js`, branché sur les events `Notification` + `Stop`
dans `~/.claude/settings.json` :
- lit le JSON de l'event sur stdin (`hook_event_name`, `message`, `cwd`…),
- envoie une notif macOS via `terminal-notifier`,
- clé de regroupement = **`ITERM_SESSION_ID`** ; clic → refocalise l'onglet iTerm2.

Or nos sessions ne tournent plus dans iTerm2 : `ITERM_SESSION_ID` est absent, mais
**`POTOF_SESSION_ID` est présent** dans l'env du process `claude`.

## Plan de branchement (le jour venu)

Contrainte : **100 % local, aucun réseau** (cf. CLAUDE.md).

1. **Côté app — un lecteur de canal local.** Deux options, au choix :
   - **Socket Unix** : l'app écoute sur `~/Library/Application Support/PotofToolkit/notif.sock`
     et lit des lignes JSON `{ potofSessionId, event, message }`.
   - **Fichier JSONL surveillé** (plus simple, sans serveur) : l'app tail un fichier
     `…/PotofToolkit/notifications.jsonl` via `DispatchSource` (vnode) ; chaque ligne
     ajoutée → un `AppNotification`.

   Le lecteur mappe `potofSessionId` → `Session.id` (l'app connaît ses sessions),
   construit un `AppNotification` (`kind = .finished` si event `Stop`, sinon `.waiting`)
   et appelle `NotificationBus.ingest(_:)` sur `main`.

2. **Côté hook — patch de `claude-notify.js`.** Quand `process.env.POTOF_SESSION_ID`
   est défini, en plus (ou au lieu) de `terminal-notifier`, écrire une ligne dans le
   canal ci-dessus :
   ```js
   const sid = process.env.POTOF_SESSION_ID;
   if (sid) {
     // append JSONL, ou connect() au socket, puis write {potofSessionId, event, message}
   }
   ```
   Garder le comportement `terminal-notifier` comme repli hors app.

3. **Côté UI — focus au clic.** `NotificationSlot` (déjà en place) : au clic sur une
   notif portant un `sessionID`, appeler `SessionStore.focus(id)` pour activer la
   session dans le centre. (À câbler quand le bus sera alimenté.)

## Pourquoi pas maintenant

Décision produit (cf. plan) : stabiliser d'abord le terminal embarqué et l'UI. Les
ancrages ci-dessus garantissent que le branchement sera **additif** (un lecteur qui
appelle `ingest`, un patch de hook), sans retoucher l'architecture.
