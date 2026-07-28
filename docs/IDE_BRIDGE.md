# Pont IDE — valider les modifications des agents Claude dans l'app

Potof Toolkit se fait passer pour un **IDE Claude Code** : un serveur **MCP sur
WebSocket** que le CLI `claude` pilote. Quand un agent veut modifier un fichier, il
appelle l'outil **`openDiff`** au lieu d'écrire ; l'app affiche le diff dans une
**fenêtre flottante**, l'utilisateur accepte / amende / refuse, et **c'est `claude` qui
écrit**. L'app ne touche jamais au disque.

Le pont sert **deux populations** d'agents :

- les `claude` **externes** — lancés par Superset, par un terminal du poste, par une
  autre app : l'app ne contrôle pas leur environnement, ils nous trouvent en scannant
  `~/.claude/ide/*.lock` (→ `IDEHost`, un seul lock pour tout `$HOME`) ;
- les sessions **possédées** par le Claude Launcher, dont l'app est le process parent
  et à qui elle injecte un port (→ `IDEServer`, un serveur par session).

Les deux convergent vers la **même surface de validation** : `DiffReviewCenter`
(file unique) + la fenêtre flottante `DiffReviewWindow`.

> ⚠️ **Protocole non-officiel, non documenté.** Tout ce qui suit a été vérifié dans le
> binaire `claude 2.1.220` (`~/.local/share/claude/versions/2.1.220`, Mach-O bun) le
> 2026-07-28. Il a **déjà** dérivé une fois de façon silencieuse (2.1.205 → 2.1.220,
> cf. « Historique de dérive »). La procédure pour re-vérifier est en fin de document ;
> les constantes sont centralisées dans `Core/IDEHost/IDEProtocolContract.swift`.

---

## Vue d'ensemble

```
Superset (ou un terminal quelconque) → zsh → claude   (cwd = un worktree)
   │
   ├─ scanne ~/.claude/ide/*.lock  → matching par PRÉFIXE de chemin sur workspaceFolders
   │    └─ exactement 1 IDE valide ? → auto-connexion (fenêtre de 30 s au démarrage)
   │
   └─ WebSocket  ws://127.0.0.1:<port>   + X-Claude-Code-Ide-Authorization: <authToken>
        ├─ initialize / notifications/initialized / ide_connected {pid}
        │     └─ IDEClientIdentity : pid ──lsof──▶ cwd ──▶ « Superset · <branche> »
        └─ tools/call openDiff        ← BLOQUANT, N en parallèle (sous-agents `Task`)
              └─ DiffReviewCenter.enqueue → fenêtre flottante
                    ├─ Refuser         → ["DIFF_REJECTED"]
                    ├─ Accepter        → ["FILE_SAVED", contenu proposé]
                    └─ Accepter amendé → ["FILE_SAVED", contenu édité]
                          └─ claude applique l'outil et écrit le fichier
                                └─ IDEContractGuard relit le disque (≤ 3 s)
```

---

## 1. Le contrat `claude 2.1.220`

### 1.1 Découverte : le lock file (`ISo`, `xSo`, `LJu`)

`claude` liste `~/.claude/ide/*.lock` (triés par mtime décroissant). **Le port est le
nom du fichier** ; le contenu porte le reste :

```json
{ "pid": 41234, "workspaceFolders": ["/Users/julien.valery"],
  "ideName": "Potof Toolkit", "transport": "ws",
  "runningInWindows": false, "authToken": "<64 hex, aléatoire>" }
```

Un lock est **valide** pour un agent si :

```
cwd === resolve(folder)  ||  cwd.startsWith(resolve(folder) + "/")   ← un des workspaceFolders
   ou   lock.port === CLAUDE_CODE_SSE_PORT                           ← court-circuit par l'env
```

⇒ **le matching est par préfixe de chemin.** Un seul dossier déclaré couvre toute son
arborescence : c'est ce qui rend possible un lock unique sur `$HOME` plutôt qu'un lock
par projet. (`transport: "ws"` ⇒ le CLI construit `ws://host:port` ; sinon il tenterait
du SSE en HTTP, que l'app ne sert pas.)

**Contrôle d'ascendance de pid** : le CLI n'exige que le lock appartienne à un process
**ancêtre** que s'il se croit dans le terminal *d'un IDE reconnu*. Sous Superset
(`TERM_PROGRAM=kitty`), il se considère en terminal externe et **saute ce contrôle** —
Potof n'a donc pas besoin d'être le parent de l'agent. Le token d'auth, lui, est
toujours exigé.

**Locks périmés** : au scan, le CLI ignore/supprime ceux dont le `pid` est mort. Un
crash de l'app ne laisse pas de lock fantôme bloquant — et `IDEServer.sweepStaleLocks()`
(appelé au démarrage) fait le ménage de **nos** locks de son côté. En revanche un lock
**vivant** n'est jamais filtré : voir §3.

### 1.2 Auto-connexion : la condition d'unicité (`ASo`, `SMt`)

L'auto-connexion est **armée** si l'une de ces conditions tient (`SMt`) :

| Condition | Statut sur ce poste |
|---|---|
| `autoConnectIde: true` dans `~/.claude.json` | **actif** — c'est ce qui fait tout marcher |
| `CLAUDE_CODE_SSE_PORT` défini | sessions possédées du Claude Launcher |
| `CLAUDE_CODE_AUTO_CONNECT_IDE=true` | non utilisé |
| terminal d'IDE détecté | non (kitty / SwiftTerm) |

> ⚠️ Ne **jamais** toucher à `autoConnectIde` dans `~/.claude.json`. `CLAUDE_CODE_AUTO_CONNECT_IDE=false`
> désarme tout, quoi que dise le réglage.

Une fois armée, `ASo` **sonde toutes les secondes pendant 30 s après le démarrage du
CLI**, et ne se connecte que s'il trouve **exactement un** IDE valide.

Deux conséquences qui coûtent des heures si on les ignore :

- **Deux IDE valides ⇒ aucune connexion automatique**, ni vers l'un ni vers l'autre.
  L'utilisateur doit taper `/ide` et choisir. Voir §3.
- **Potof doit être debout avant l'agent.** Passé les 30 s, plus aucune tentative :
  un agent lancé avant l'app ne se connectera jamais tout seul (remède : `/ide`).
  C'est pour ça qu'`IDEHost.shared.start()` est dans `applicationDidFinishLaunching`,
  juste après le balayage des locks orphelins.

### 1.3 Handshake WebSocket

Requête d'upgrade émise par `claude` :

```
GET / HTTP/1.1
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: <base64>
Sec-WebSocket-Protocol: mcp                           ← à ÉCHO dans la 101
X-Claude-Code-Ide-Authorization: <authToken du lock>  ← à VALIDER
```

Réponse : `101 Switching Protocols`, `Sec-WebSocket-Accept = base64(sha1(key + GUID))`
(GUID `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`) et `Sec-WebSocket-Protocol: mcp`. Sans
l'écho du sous-protocole, `claude` referme aussitôt.

`NWProtocolWebSocket` (l'API haut niveau de `Network.framework`) ne donne **pas** accès
aux en-têtes côté serveur : impossible d'y lire le token ni d'écho le sous-protocole.
D'où un `NWListener` **TCP nu** et un handshake + framing RFC 6455 faits à la main
(`IDEConnection`) — c'est aussi ce qui évite d'ajouter une dépendance (invariant projet).

Sécurité : bind `127.0.0.1` (barrière principale) **+** validation du token
(ceinture/bretelles). Le périmètre `$HOME` élargit la surface — n'importe quel process
local peut frapper à la porte —, le token est la seule chose qui l'arrête. **Il n'est
jamais journalisé.**

### 1.4 Éligibilité du diff IDE (`eSd`)

Avant même de penser à `openDiff`, le CLI filtre :

```js
if (tool !== Edit && tool !== Write) return null;   // ← SEULEMENT Edit et Write
if (!clients.some(c => c.type === "connected" && c.name === "ide")) return null;
if (settings.diffTool !== "auto") return null;      // défaut "auto"
if (filePath.endsWith(".ipynb")) return null;
```

Un `null` ici ⇒ **prompt de permission dans le terminal**, comportement natif. Ce n'est
pas un défaut d'implémentation de l'app : c'est la frontière du protocole (§4).

### 1.5 La séquence `openDiff` et la table des réponses (`Jbd`, `kq_`/`Aq_`/`Rq_`)

```
→ tools/call openDiff { old_file_path, new_file_path (= le même),
                        new_file_contents (le fichier ENTIER, déjà patché par le CLI),
                        tab_name: "✻ [Claude Code] f.swift (ab12cd) ⧉" }     BLOQUANT
← result.content = [ … ]
```

| `content` renvoyé | Interprétation côté CLI |
|---|---|
| `[{type:"text",text:"FILE_SAVED"}, {type:"text",text:"<contenu final>"}]` | **Accepté** — `newContent` = le **2ᵉ bloc** |
| `[{type:"text",text:"TAB_CLOSED"}]` | Accepté **tel que proposé** |
| `[{type:"text",text:"DIFF_REJECTED"}]` | `newContent = oldContent` (= le disque) |
| **autre chose** | `throw Error("Not accepted")` → log `Failed to show diff in IDE` |

> ⚠️ **`FILE_SAVED` porte DEUX blocs.** Le prédicat côté CLI est littéralement
> `content[0].text === "FILE_SAVED" && typeof content[1].text === "string"`. Avec un
> seul bloc, `content[1]` est `undefined` → `TypeError` → catch → « Not accepted » :
> la revendication de permission n'est pas prise et **l'édition n'est jamais
> appliquée**. C'est exactement le bug qui a dormi entre 2.1.205 et 2.1.220.

> ⚠️ **Ne jamais répondre `TAB_CLOSED` à un `openDiff`.** Dans ce contexte-là, ça vaut
> « accepté tel que proposé » : une confusion de fabrique écrirait le fichier sans que
> personne n'ait validé. `TAB_CLOSED` est l'accusé de réception de l'outil `close_tab`,
> et rien d'autre. (Les fabriques sont séparées dans `IDEProtocolContract` pour cette
> raison précise.)

Puis, immédiatement (`tSd`) :

```js
const hunks = Ybd(filePath, oldContent, newContent, "single");
if (hunks.length === 0) { deny("User denied via IDE"); cancelAndAbort(); }
else                    { allow({ updatedInput: Iq_(tool, input, hunks) }); }
```

### 1.6 Le fait central : **le panneau de diff EST le prompt de permission**

`tSd` rend un `allow` / `deny`. Quand la réponse est bien formée, **aucun prompt
n'apparaît dans le terminal** : la fenêtre de revue *est* la décision de permission.

Trois corollaires structurants :

1. **On ne tape plus jamais `Entrée` dans un terminal après une acceptation.** L'ancien
   hack (« renvoyer `FILE_SAVED` puis répondre Yes au prompt, avec un repli aveugle à
   6 s ») n'existait que parce que notre réponse était malformée. Réintroduit
   aujourd'hui, il validerait *n'importe quel* prompt présent à cet instant — un
   « trust this folder », un `Bash` proposé entre-temps. Il ne reste qu'une
   surveillance **conditionnelle** dans `SessionStore.watchStrayPermissionPrompt` :
   elle ne tape que si un prompt **apparaît vraiment** après coup, et lève alors le
   bandeau de dérive (§5).
2. **Le contenu renvoyé devient l'input réel de l'outil**, donc on peut **accepter en
   modifiant**. `Idt(singleHunk: true)` calcule le diff avec `context: 1e5` : le hunk
   reconstruit couvre tout le fichier (`old_string` = ancien fichier entier,
   `new_string` = nouveau fichier entier). Sûr y compris pour `Write`.
   ⚠️ **Limite dure** : `Iq_` ne reprend que `hunks[0]`. Au-delà de ~100 000 lignes le
   diff se scinde et **seul le premier hunk est appliqué** — d'où le seuil
   `editableLineLimit` de `DiffReviewView`, qui désactive l'édition libre et l'explique
   plutôt que d'écrire une version tronquée.
3. **Un contenu identique au disque équivaut à un refus.** Le CLI diffe
   `disque → contenu renvoyé` ; s'il est vide, il n'y a aucun hunk et il en déduit
   « refusé par l'utilisateur ». C'est vrai aussi si l'utilisateur édite jusqu'à revenir
   au contenu d'origine — d'où l'avertissement affiché **avant** le clic
   (`DiffReviewView.isNoOp`, comparaison octet à octet : un `\n` final compte).

### 1.7 Les autres outils MCP

`openDiff` est le seul « actif ». Les autres sont des stubs neutres que `claude`
consomme pour du contexte : `getDiagnostics` (`"[]"`), `getWorkspaceFolders`,
`getOpenEditors`, `getCurrentSelection` / `getLatestSelection`, `close_tab`
(`TAB_CLOSED`), `closeAllDiffTabs` (`CLOSED_<n>_DIFF_TABS`).

> ⚠️ Un `tools/call` **non servi** ne produit aucune erreur visible : il ne reçoit
> jamais de réponse et **fige l'agent**. `getLatestSelection` en est l'exemple — le CLI
> l'appelle sans qu'il figure dans notre `tools/list`. On le sert quand même. La casse
> est hétérogène côté CLI (`openDiff` en camel, `close_tab` en snake) : ne pas
> « harmoniser ».

### 1.8 Concurrence : N `openDiff` en vol

Les sous-agents `Task` d'un même `claude` émettent des `openDiff` **concurrents**, et
l'utilisateur fait tourner 4–5 agents en parallèle. `openDiff` étant bloquant, une
demande perdue = un agent figé indéfiniment. D'où l'invariant d'`IDEConnection` :

> toute demande entrée dans `inFlight` en sort par **exactement une** résolution —
> verdict de l'utilisateur, `close_tab`/`closeAllDiffTabs`, ou purge à la fermeture.

Le CLI ne fournit aucune identité de demande : l'appariement repose sur un **UUID
local** généré à la réception (`IDEDiffRequest.id`), seul fil entre un clic
« Accepter » et l'appel JSON-RPC précis qu'il débloque. L'`id` JSON-RPC est ré-écho
**tel quel** (la spec autorise nombre *ou* chaîne).

---

## 2. Les deux hôtes

| | `IDEHost` (global) | `IDEServer` (par session) |
|---|---|---|
| **Sert** | les agents **externes** (Superset, terminaux du poste) | les sessions **possédées** du Claude Launcher |
| **Découverte** | scan des locks, matching par préfixe | `CLAUDE_CODE_SSE_PORT` injecté au spawn |
| **Instances** | **une** (singleton app-level), 1 port, 1 lock, N connexions | **une par session**, 1 port, 1 lock chacune |
| **`workspaceFolders`** | le périmètre réglable (`$HOME` par défaut), affiné au cwd réel dès que le pid est résolu | le dossier de la session, exact d'emblée |
| **Cycle de vie** | `applicationDidFinishLaunching` → `applicationWillTerminate` | `TerminalController.start` → fermeture de session |
| **Identité du client** | déduite (`ide_connected {pid}` → `lsof` → worktree → branche) | connue (c'est notre session) |

**Pourquoi les deux coexistent** plutôt qu'un hôte unique : le port injecté
**court-circuite** la validation par préfixe (`lock.port === CLAUDE_CODE_SSE_PORT`).
Une session possédée atteint donc *toujours* son propre serveur — jamais l'hôte global,
jamais le lock d'un autre IDE, quelle que soit l'ambiguïté ambiante. C'est ce routage
exact qui permet à `InitClaudeMdCoordinator` de savoir de quelle session vient un
aperçu. Un hôte unique perdrait cette information et hériterait de la fragilité de la
découverte.

Le port injecté est aussi la **seule** variable d'environnement du pont.
`ENABLE_IDE_INTEGRATION=true`, injectée jusqu'ici, a été retirée : **la chaîne
n'existe plus dans le binaire 2.1.220** — variable morte, la garder entretenait la
croyance qu'elle conditionnait quelque chose.

---

## 3. Le périmètre `$HOME` et son revers

Le lock global déclare `workspaceFolders: ["/Users/<user>"]` : par préfixe, il attrape
**tous** les agents du poste. C'est le but — Superset ne nous laisse rien injecter, la
découverte par lock est notre seul moyen de les servir.

> ⚠️ **Le revers** : deux IDE valides sur le même dossier ⇒ **plus d'auto-connexion du
> tout**, ni vers l'un ni vers l'autre (§1.2). WebStorm publiait ses propres locks
> (`~/WebstormProjects/…`) ; pour un `claude` lancé dans un projet ouvert dans WebStorm,
> il y aurait eu 2 locks valides et il aurait fallu taper `/ide` à chaque fois.
> **Décision assumée : le plugin Claude Code de WebStorm a été retiré**, Potof est le
> seul IDE de tout `$HOME`. Contrepartie : plus d'intégration Claude ↔ WebStorm. Le
> conflit reviendrait à l'identique avec VS Code, Cursor ou tout autre JetBrains.

`IDEHost.logCompetingLocks()` journalise (sans rien modifier) tout lock **vivant** qui
n'est pas le nôtre au démarrage — c'est la première chose à regarder dans `ide.log`
quand un agent ne se connecte plus.

L'amortisseur, si un autre IDE réapparaît, est le réglage de périmètre — menu
**« Hôte IDE »** de la barre de menus (`IDEHostSettings`, clé `ideHost.scope`) :

| Périmètre | `workspaceFolders` | Quand |
|---|---|---|
| **Tout le dossier utilisateur** (défaut) | `$HOME` | nominal — tous les agents du poste |
| **Worktrees Superset uniquement** | `~/.superset/worktrees` | repli sûr : aucun IDE classique n'ouvre cette arborescence ⇒ zéro conflit possible, au prix des agents lancés d'un terminal ordinaire |
| **Désactivé** | *(aucun lock)* | l'hôte s'arrête ; les agents externes retombent sur le prompt de permission de leur terminal. Les sessions possédées ne sont **pas** concernées (port injecté) |

Le changement s'applique **à chaud** (`IDEHost.applyCurrentScope()` republie le lock,
même port et **même token** — le changer invaliderait un agent qui a lu le lock mais
n'a pas encore ouvert sa WebSocket). Rétrécir le périmètre **ne coupe pas** les
connexions en cours : le lock ne sert qu'à la découverte, et couper laisserait des
`openDiff` en vol sans réponse. Seul « Désactivé » coupe, en rendant un `DIFF_REJECTED`
propre à chaque demande.

Le panneau **« Clients connectés… »** (même menu) répond à la seule question qui se pose
en pratique : l'hôte tourne-t-il, sur quel périmètre, et cet agent est-il connecté ?

---

## 4. Ce que le pont ne couvre **pas**

À dire honnêtement plutôt que de laisser croire à une interception totale :

| Hors périmètre | Pourquoi |
|---|---|
| **`Bash`**, outils **MCP**, `WebFetch`, sortie de **plan mode**, toute permission qui n'est pas une édition | `eSd` ne connaît que `Edit` et `Write` |
| **Notebooks** (`.ipynb`, `NotebookEdit`) | exclus explicitement par `eSd` |
| `diffTool: "terminal"` dans les settings | `eSd` exige `"auto"` |
| Agents en **`acceptEdits`** ou **`--dangerously-skip-permissions`** | pas de demande de permission ⇒ pas d'`openDiff` du tout |
| Agents démarrés **avant** l'app | la fenêtre d'auto-connexion de 30 s est passée (remède : `/ide`) |
| Agents dont le `cwd` sort du périmètre servi | le lock ne matche pas |

> ⚠️ Ne **PAS** lancer `claude` en `--permission-mode acceptEdits` en espérant fluidifier
> les choses : dans ce mode il n'appelle plus `openDiff`, écrit directement, et on perd
> l'aperçu **et** la validation.

Tout ce qui n'est pas couvert continue de fonctionner normalement, avec le prompt de
permission du terminal. Rien n'est cassé — c'est juste moins confortable.

### 4.1 La course du **premier tour** (mesurée)

⚠️ Piège silencieux, spécifique aux agents lancés avec le prompt **en argument**
(`claude "<consigne>"`) — c'est exactement ainsi que **Superset** démarre les siens.

`eSd` lit `r.options.mcpClients`, l'instantané des clients MCP **du tour courant**. Cet
instantané est pris au moment où le message est soumis. Avec un prompt en argv, c'est au
démarrage du CLI — **en concurrence avec la connexion du client `ide`**, qui aboutit une
quarantaine de millisecondes plus tard. Si l'agent édite avant que la connexion ne soit
enregistrée, pas d'`openDiff` : l'édition retombe sur le prompt terminal, alors même que
la WebSocket est établie et que `claude --debug` affiche
`MCP server "ide": Successfully connected`.

**La perte est bornée au premier tour.** La boucle de requête rafraîchit l'instantané
entre chaque tour :

```js
if (er.options.refreshMcpClients) {
    let rt = er.options.refreshMcpClients();
    er = {...er, options: {...er.options, mcpClients: rt}}
}
```

Vérifié expérimentalement (`POTOF_SELFTEST_ARGV` + `POTOF_SELFTEST_RELEASE_ON`, qui
retient le `101` du handshake jusqu'à l'apparition d'un marqueur à l'écran, reproduit 3×) :
avec deux tours d'outils complets passés **sans aucun client `ide`**, l'`Edit` suivant
passe bien par `openDiff`. Contrôle inverse, même build : édition au tour 1 avec handshake
retenu ⇒ pas d'`openDiff`, prompt terminal, 4/8 FAIL.

| Situation | Couvert ? |
|---|---|
| Prompt **tapé** dans une session interactive | ✅ toujours |
| Prompt en **argv**, agent qui lit/cherche avant d'éditer | ✅ (l'édition tombe au tour ≥ 2) |
| Prompt en **argv**, dont la **toute première** action est `Edit`/`Write` | ⚠️ course — perdue une fois sur deux environ |
| Tous les tours suivants, toute relance | ✅ toujours |

En pratique un agent explore avant d'écrire, donc l'exposition est étroite — mais elle est
réelle et **silencieuse** (l'édition réapparaît simplement sous forme de prompt terminal).
Aucune correction côté app n'est possible ni souhaitable : le lock, le handshake et la
WebSocket fonctionnent ; c'est le CLI qui ne nous avait pas encore enregistrés quand il a
construit ce tour-là. Une temporisation par hook `SessionStart` a été envisagée puis
écartée : effet non vérifié, latence sur **toutes** les sessions, pour une fenêtre étroite.

---

## 5. Garde-fous contre la dérive du contrat

Le mode d'échec redouté est vicieux : l'utilisateur clique « Accepter », l'app est
contente, **et rien n'est écrit**. C'est précisément ce que produisait la réponse à un
bloc — pendant des mois, masqué par le hack du prompt terminal. `IDEContractGuard`
existe pour rendre la prochaine dérive impossible à rater.

**1. Vérification post-acceptation — le signal qui fait autorité.** Après un
`.saved(content:)`, relecture du fichier pendant ≤ 3 s (sondage à 120 ms, plus un sursis
unique de 1,5 s si ce qu'on lit est un **préfixe strict** de l'attendu = écriture en
cours). Ce signal ne suppose **rien** du protocole : l'app n'écrit jamais, donc le
fichier ne peut avoir changé que parce que `claude` a compris notre acceptation. Le
diagnostic distingue trois cas — inchangé (« non appliqué »), supprimé, ou écrit
différemment — parce que les confondre, c'est soit accuser le protocole à tort, soit
rater une vraie dérive.

**2. Empreinte de version — informatif, n'affiche rien.** La version annoncée dans
`clientInfo` au `initialize` est comparée à
`IDEProtocolContract.lastValidatedClaudeVersion` et **journalisée**. Un écart n'est pas
une panne (le pont survit à la plupart des montées de version) ; lever un bandeau à
chaque mise à jour garantirait que plus personne ne le lit le jour où il compte. Le
contexte de version est en revanche injecté dans le message quand une **vraie** dérive
est détectée : « ça ne marche pas **et** tu tournes sur une version non validée » est
actionnable.

**3. Prompt de permission égaré.** Sur une session possédée, si un prompt apparaît dans
le terminal **après** une acceptation (`SessionStore.watchStrayPermissionPrompt`, ~2 s
de veille) : le CLI n'a pas pris notre revendication. On y répond pour ne pas bloquer la
session **et** on lève le drapeau. Jamais de frappe à l'aveugle : si l'écran montrait
déjà un prompt au moment du verdict, la surveillance se désarme.

**4. Le bandeau.** Orange, en tête de la fenêtre de revue, avec la raison, le contexte
de version et le renvoi ici. Il **ne se réarme pas tout seul** : une acceptation
réussie derrière ne l'efface pas, seul un humain le referme. C'est délibéré — une
dérive intermittente qui s'auto-efface, c'est le mode d'échec d'origine.

### Historique de dérive

| Point | 2.1.205 (spike) | 2.1.220 (vérifié) |
|---|---|---|
| `ENABLE_IDE_INTEGRATION` | injecté dans l'env | **la chaîne n'existe plus** dans le binaire |
| Acceptation `FILE_SAVED` | 1 bloc (croyance) | **2 blocs obligatoires** |
| Prompt terminal après acceptation | « la vraie porte » | **n'existe pas** si la réponse est bien formée |
| Un `openDiff` en attente par session | supposé suffisant | faux : les sous-agents `Task` en émettent en parallèle |

---

## 6. Re-valider après une montée de version de `claude`

### 6.1 D'abord : l'auto-test

```bash
swift build
POTOF_IDE_LOG_FILE=/tmp/ide.log .build/debug/potof-toolkit --ide-selftest [--e2e]
```

Le mode monte un hôte **isolé** (log redirigé, sans toucher à l'app en cours) et sort un
compte rendu par point de contrat : handshake, auth, `tools/list`, `openDiff` reçu,
`FILE_SAVED` 2 blocs accepté, fichier écrit, aucun prompt terminal. `--e2e` pousse
jusqu'à piloter un vrai `claude` sur un dossier temporaire et **assert sur le contenu du
fichier** : c'est le seul test qui prouve la chaîne complète. La commande décrit sa
propre sortie — s'y fier plutôt qu'à ce document.

> ⚠️ Ne **jamais** lancer l'auto-test en laissant l'app installée tourner sans y penser :
> deux locks Potof vivants = deux IDE « valides » = plus d'auto-connexion nulle part
> (§1.2). Même piège avec un `open -n` d'un bundle de test.

### 6.2 Ensuite : relire le binaire

C'est ce qui transforme un diagnostic de plusieurs heures en quelques minutes. Le
binaire `claude` est un **Mach-O bun** : le bundle JavaScript minifié y est en clair,
donc lisible avec `strings` / `grep -a` / `perl -0777`.

```bash
CLAUDE_BIN=~/.local/share/claude/versions/$(claude --version | cut -d' ' -f1)

# Le prédicat d'acceptation — LE point à vérifier en priorité
LC_ALL=C perl -0777 -ne 'while(/(.{0,300})FILE_SAVED(.{0,300})/gs){print "$1<<<>>>$2\n\n"}' "$CLAUDE_BIN"

# N'importe quelle fonction minifiée, avec son corps
LC_ALL=C perl -0777 -ne 'while(/function eSd(.{100,900}?)function /gs){print "$1\n\n"}' "$CLAUDE_BIN"

# Une variable d'env est-elle encore vivante ?
strings -n 6 "$CLAUDE_BIN" | grep -c ENABLE_IDE_INTEGRATION     # 0 en 2.1.220
```

Les symboles minifiés changent d'une version à l'autre, mais les **chaînes littérales**
(`FILE_SAVED`, `DIFF_REJECTED`, `openDiff`, `User denied via IDE`, `Not accepted`,
`Failed to show diff in IDE`) sont stables : partir d'elles pour retrouver la fonction
qui les entoure, puis remonter ses appelants.

Carte des symboles **en 2.1.220** — à re-localiser, pas à réutiliser tels quels :

| Symbole | Rôle | Ce qu'on y vérifie |
|---|---|---|
| `ISo` | énumère les IDE et décide de leur validité | matching par préfixe ; court-circuit `CLAUDE_CODE_SSE_PORT` ; contrôle d'ascendance de pid conditionné au terminal d'IDE ; `CLAUDE_CODE_IDE_SKIP_VALID_CHECK` |
| `xSo` | liste les `*.lock`, triés par mtime | emplacement et forme du répertoire de locks |
| `LJu` | lit/parse un lock | champs attendus (`port`, `workspaceFolders`, `pid`, `authToken`, `useWebSocket`) |
| `SMt` | l'auto-connexion est-elle armée ? | `autoConnectIde`, `CLAUDE_CODE_AUTO_CONNECT_IDE`, `CLAUDE_CODE_SSE_PORT` |
| `ASo` | boucle d'auto-connexion | **30 s**, sondage 1 s, **`length === 1`** (unicité) |
| `eSd` | éligibilité du diff IDE | `Edit`/`Write` seulement, `diffTool === "auto"`, `.ipynb` exclu |
| `Jbd` | émet `openDiff`, interprète la réponse | **la table des réponses** (§1.5) |
| `kq_` / `Aq_` / `Rq_` | prédicats `FILE_SAVED` / `TAB_CLOSED` / `DIFF_REJECTED` | ⭐ `kq_` : `e[0].text==="FILE_SAVED" && typeof e[1].text==="string"` — **les 2 blocs** |
| `tSd` | orchestre permission + diff | `hunks.length === 0` ⇒ `deny("User denied via IDE")` sinon `allow(updatedInput)` |
| `Ybd` / `Idt` | recalcule les hunks | `context: 1e5` en mode `singleHunk` |
| `Iq_` | construit l'`updatedInput` | ⚠️ **`hunks[0]` seulement** — la limite de l'édition libre |

Une fois le contrat re-vérifié : mettre à jour
`IDEProtocolContract.lastValidatedClaudeVersion`, les fabriques concernées, **et ce
document**.

### 6.3 Validation manuelle de bout en bout

1. `swift build`, puis packager **dans le scratchpad** (jamais dans `~/Applications`
   hors `main`, cf. `CLAUDE.md`) et lancer par chemin explicite :
   `open -n "<scratchpad>/Potof Toolkit.app"`.
2. `cat ~/.claude/ide/*.lock` → une entrée `"ideName":"Potof Toolkit"` avec le bon
   `workspaceFolders`. Une seule autre entrée vivante suffit à tout casser.
3. Dans Superset, ouvrir un worktree et lancer un agent : `/ide` doit afficher
   « Potof Toolkit » connecté (ou l'auto-connexion a déjà eu lieu).
4. Demander une édition simple → la fenêtre flottante s'ouvre et **aucun prompt de
   permission n'apparaît dans le terminal Superset**.
5. Refuser → fichier intact, l'agent l'annonce. Accepter → fichier écrit.
   Éditer puis accepter → **le contenu édité** est sur le disque.
6. Deux agents en parallèle → deux entrées dans la file, résolvables indépendamment.
7. `tail -f ~/Library/Application\ Support/PotofToolkit/ide.log` pour tout le détail.

---

## 7. Journal

`~/Library/Application Support/PotofToolkit/ide.log`, **tronqué à chaque lancement** de
l'app (son contenu réfère des connexions mortes). Redirigeable par
`POTOF_IDE_LOG_FILE`. Va aussi dans `os_log` (`subsystem: com.potof.toolkit`,
`category: ide`).

On y trouve : les locks concurrents vivants, chaque handshake, l'identification des
clients, chaque `openDiff` (id court, onglet, nombre en vol), chaque verdict avec sa
durée d'attente, et les conclusions du garde-fou de contrat.

> ⚠️ Le log ne contient **jamais** de contenu de fichier ni de token — seulement des
> tailles en octets. Ne pas régresser là-dessus : il est lu et collé en clair pendant
> les diagnostics.

---

## 8. Fichiers

```
Core/IDEHost/                 Le pont : il sert des agents EXTERNES, ce n'est plus une
                              affaire de Claude Launcher (d'où Core/ et non Tools/)
  IDEProtocolContract.swift   ⭐ LE contrat en un seul endroit : formes de réponse openDiff,
                              noms d'outils, en-tête d'auth, version validée
  IDEBridge.swift             Types (IDEDiffRequest/Verdict, IDEDiffHandlers) + logger IDELog
  IDEHost.swift               ⭐ Hôte global : 1 port, 1 lock ($HOME), 1 listener, N connexions
  IDEServer.swift             Serveur d'UNE session possédée (port injecté) + sweepStaleLocks
  IDEConnection.swift         Handshake + framing RFC 6455 + JSON-RPC/MCP, N openDiff en vol
  IDEClientIdentity.swift     pid (ide_connected) → cwd (lsof) → worktree → « Superset · branche »
  IDEContractGuard.swift      ⭐ Vérif post-acceptation + empreinte de version + bandeau
  IDEHostSettings.swift       Périmètre servi / activation à la réception / expiration
  IDEHostMenu.swift           Menu « Hôte IDE » de la barre de menus
  IDEHostStatusView.swift     Panneau de diagnostic (port, périmètre, clients) — lecture seule
Core/DiffReview/              La surface de validation, commune à toutes les origines
  DiffReviewCenter.swift      ⭐ File d'attente unique + résolution (singleton app-level)
  DiffReviewWindow.swift      NSPanel flottant + bannières + cycle de vie
  DiffReviewView.swift        Corps : en-tête agent/fichier, unifié | côte à côte | édition
  DiffEditorView.swift        NSTextView monospace pour amender le contenu avant acceptation
Core/Diff/                    Moteur de diff PARTAGÉ (aucun lien avec le pont ni avec git)
  DiffModel.swift             DiffComputer / FileDiff / DiffLine
  DiffLineRow, DiffHalfRow, SideBySideDiff, DiffLayoutMode   rendus mutualisés
```

Câblage :

- `AppDelegate` — `IDELog.startSession()`, `IDEServer.sweepStaleLocks()` puis
  `IDEHost.shared.start()` au démarrage (avant tout agent) ; `IDEHost.shared.stop()` à
  l'extinction (**supprime le lock** : un lock survivant enverrait les prochains
  `claude` sur un port mort, et le CLI ne purge que les pids morts — un pid recyclé
  passerait au travers). Le menu « Hôte IDE » est inséré dans `NSApp.mainMenu`.
- `NotificationCenterCoordinator` — amorce `DiffReviewWindowController.start()` et
  **compose** la pastille du Dock : `non-lues + diffs en attente`. La part « diffs »
  n'est **pas** effaçable par une simple activation de l'app (derrière chaque demande,
  un agent est bloqué ; revenir dans l'app ne décide de rien). Route aussi le clic sur
  nos bannières vers `bringToFront()`.
- `TerminalController` — crée l'`IDEServer` de la session **avant** le spawn, pour
  injecter `CLAUDE_CODE_SSE_PORT` dans l'environnement du shell.
- `SessionStore` — `presentDiff` enfile dans `DiffReviewCenter` (plus d'aperçu in situ :
  le terminal reste visible en permanence) et enveloppe la complétion pour enchaîner sur
  `InitClaudeMdCoordinator` et la surveillance de prompt égaré.
