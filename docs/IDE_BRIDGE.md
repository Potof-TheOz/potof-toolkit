# Pont IDE — aperçu des diffs Claude dans l'app

But : prévisualiser les modifications proposées par `claude` **dans Potof Toolkit**
(accepter/refuser), sans passer par un IDE tiers. Mécanisme : l'app se fait passer
pour un **IDE Claude Code**, c.-à-d. un **serveur MCP** que le CLI `claude` pilote.

> ⚠️ Ce protocole est **non-officiel** (reverse-engineered). Les détails ci-dessous
> sont **vérifiés empiriquement** contre `claude 2.1.205` (voir « Re-valider »). Il
> peut changer d'une version à l'autre : tout est isolé dans
> `Tools/ClaudeLauncher/IDE/` et re-testable en une commande.

## Vue d'ensemble

```
TerminalController.start(session)
  └─ IDEServer(session)                 1 serveur par session
       ├─ réserve un port éphémère (127.0.0.1)
       ├─ écrit ~/.claude/ide/<port>.lock   {pid, workspaceFolders, ideName, transport, authToken}
       └─ NWListener WebSocket (TCP brut + framing RFC 6455 fait main)
  └─ spawn $SHELL -l -i  avec env +=  CLAUDE_CODE_SSE_PORT=<port>  ENABLE_IDE_INTEGRATION=true
        └─ claude lit le lock, se connecte en WebSocket (JSON-RPC 2.0 / MCP)
```

L'env injecté **prime sur le scan des locks** : même si un WebStorm est ouvert (avec
ses propres locks), `claude` lancé par Potof se connecte à **notre** port.

## Handshake WebSocket (vérifié)

Requête d'upgrade envoyée par `claude` :

```
GET / HTTP/1.1
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: <base64>
Sec-WebSocket-Protocol: mcp                         ← à ÉCHO dans la 101
Sec-WebSocket-Extensions: permessage-deflate; ...   ← optionnel, on NE négocie PAS
X-Claude-Code-Ide-Authorization: <authToken du lock>  ← à VALIDER
```

Réponse : `101 Switching Protocols` avec `Sec-WebSocket-Accept = base64(sha1(key + GUID))`
(GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`) et `Sec-WebSocket-Protocol: mcp`.

`NWProtocolWebSocket` (API haut niveau) ne laisse **pas** lire ces headers côté serveur
→ on fait le handshake + le framing à la main sur un `NWListener` TCP. Sécurité : bind
`127.0.0.1` (barrière principale) **+** validation du token (ceinture/bretelles).

## Séquence complète d'une édition (vérifiée)

**⚠️ Découverte cruciale (le point qui coûte des heures si on l'ignore) :** `openDiff`
n'est qu'un **aperçu**. En mode permission **par défaut**, l'approbation réelle est un
**prompt de permission dans le TERMINAL** que Claude affiche *après* `openDiff`.
Renvoyer `FILE_SAVED` seul **n'écrit rien** — ça ne fait qu'ouvrir/fermer l'onglet diff.

```
→ initialize            (client protocolVersion "2025-11-25")   ← on écho sa version
← result {protocolVersion, capabilities:{tools:{}}, serverInfo}
→ notifications/initialized ; → ide_connected {pid}              ← notifs, rien à répondre
→ tools/list            ← on annonce openDiff + stubs
→ tools/call closeAllDiffTabs {}                → "CLOSED_0_DIFF_TABS"
→ tools/call getDiagnostics {}                  → "[]"
→ tools/call openDiff { old_file_path, new_file_path (=même),
                        new_file_contents (fichier ENTIER),
                        tab_name: "✻ [Claude Code] f.txt (ab12cd) ⧉" }   ← BLOQUANT (aperçu)
← result { content:[{type:text, text:"FILE_SAVED" | "DIFF_REJECTED"}] }
   ⇩ si FILE_SAVED, Claude affiche DANS LE TERMINAL :
   [terminal]  Do you want to make this edit to f.txt?
               ❯ 1. Yes    2. Yes, allow all edits…    3. No       ← LA VRAIE PORTE
→ tools/call close_tab { tab_name }   (×2)      → "TAB_CLOSED"
→ tools/call getDiagnostics { uri }             → "[]"
```

### Qui écrit le fichier, et comment on accepte

L'app **ne touche jamais au disque**. C'est **Claude** qui écrit — mais uniquement une
fois le **prompt terminal** validé (`1. Yes`).

| Verdict `openDiff` | Suite |
|---|---|
| `DIFF_REJECTED` | Claude **abandonne** — aucun prompt terminal, fichier intact. |
| `FILE_SAVED`    | Claude affiche le **prompt terminal** ; l'édition s'applique si on répond « Yes ». |

Donc le bouton **Accepter** fait DEUX choses (`SessionStore.resolveDiff` →
`confirmEditInTerminal`) : renvoyer `FILE_SAVED`, PUIS **répondre « Yes » au prompt
terminal**. On détecte l'apparition du prompt dans le buffer **rendu**
(`TerminalController.screenText` via `getBufferAsData`), puis on envoie `Entrée`
(`sendKeys`) ; repli aveugle à ~6 s si non détecté (le prompt est alors forcément là).
**Refuser** renvoie simplement `DIFF_REJECTED`.

> ⚠️ **Ne PAS lancer `claude` en `--permission-mode acceptEdits`** : dans ce mode Claude
> **n'appelle plus `openDiff` du tout** et écrit directement → on perd l'aperçu. Le mode
> par défaut (celui avec prompt terminal) est donc requis. Testé aussi : usurper
> l'`ideName` (« Visual Studio Code ») **ne supprime pas** le prompt terminal.

## Outils exposés

- `openDiff` — le seul « actif » (aperçu + verdict). Voir ci-dessus.
- Stubs neutres consommés par Claude pour du contexte : `getDiagnostics` (`"[]"`),
  `getWorkspaceFolders` (dossier de la session), `getOpenEditors`, `getCurrentSelection`,
  `close_tab`, `closeAllDiffTabs`.

## Lock file `~/.claude/ide/<port>.lock`

```json
{ "pid": <pid app>, "workspaceFolders": ["<dossier session>"],
  "ideName": "Potof Toolkit", "transport": "ws",
  "runningInWindows": false, "authToken": "<opaque, aléatoire>" }
```

Cycle de vie : écrit par `IDEServer.start`, supprimé par `IDEServer.stop`
(fermeture de session). `IDEServer.sweepStaleLocks()` (au démarrage de l'app) purge les
locks Potof dont le `pid` est mort (nettoyage post-crash) — ne touche pas aux autres IDE.

## Fichiers

```
Tools/ClaudeLauncher/IDE/
  IDEBridge.swift        Types (IDEDiffRequest/Verdict, IDEDiffHandlers) + logger (IDELog)
  IDEServer.swift        NWListener + lock file + port + sweep (1 par session)
  IDEConnection.swift    Handshake WebSocket + framing RFC 6455 + dispatch JSON-RPC/MCP
  DiffModel.swift        Calcul du diff (rognage préfixe/suffixe + LCS + garde-fou mémoire)
  DiffOverlayView.swift  Panneau SwiftUI : diff unifié + Accepter/Refuser
```
Câblage :
- `TerminalController` : serveur + injection env, relais `onOpenDiff`/`onCloseTab`,
  `sendKeys`/`screenText` (répondre au prompt terminal), arrêt à `.terminate`.
- `SessionStore` : `pendingDiffs` (aperçus en attente), `presentDiff`, `resolveDiff`,
  `confirmEditInTerminal` (réponse « Yes »).
- `ClaudeLauncherView` : le panneau **remplace** le terminal (n'est PAS un overlay —
  un overlay SwiftUI au-dessus du `NSView` SwiftTerm ne capterait pas les clics :
  fall-through du hit-test vers le terminal en dessous).
- `AppDelegate` : `IDELog.startSession()` + `IDEServer.sweepStaleLocks()` au démarrage.

## Re-valider (après une montée de version de `claude`)

Le serveur de production tourne en isolation via un drapeau diagnostic :

```bash
swift build
POTOF_IDE_LOG_FILE=/tmp/ide.log .build/debug/potof-toolkit --ide-selftest /chemin/projet
# → imprime PORT=<n>, écrit le lock. Puis, dans le projet, avec un vrai claude :
CLAUDE_CODE_SSE_PORT=<n> ENABLE_IDE_INTEGRATION=true claude   # (interactif)
# demander une édition → /tmp/ide.log doit montrer handshake + openDiff.
```

`onOpenDiff` non fixé ⇒ refus systématique (le fichier reste intact) : idéal pour
valider le tuyau sans effet de bord.
