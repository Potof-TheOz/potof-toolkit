# Claude Scheduler — lancer `claude` à heure fixe dans un dossier

Quatrième outil du toolkit. Une planification, c'est un **dossier**, un **préscript** shell
facultatif, un **prompt** et une **cadence**. L'app génère puis entretient un **job
launchd** qui rappelle son propre binaire en mode **headless**. Ce runner exécute le
préscript, puis lance `claude` en **session interactive** dans un pseudo-terminal qu'il
possède. La GUI rejoue la session en direct, et Claude Launcher sait la reprendre.

Il remplace le Superset Scheduler (v1), retiré avec l'abandon de Superset. Pourquoi plus
d'IDE : [ADR 0001](adr/0001-scheduler-claude-vanilla-sans-ide.md). Pourquoi un PTY et pas
`claude -p` : [ADR 0002](adr/0002-scheduler-session-interactive-pty.md).

> **Ce que l'outil garantit : que la session a rendu la main.** Le statut de succès
> s'appelle `completed` et **jamais** `ok` : il dit que le hook `Stop` a tiré et que la
> session s'est fermée, pas que le travail est juste. La vérification du livrable est du
> métier, elle reste hors de l'outil.

## Vue d'ensemble

```
SchedulerView / ScheduleFormView (SwiftUI — projections jetables)
   │  Enregistrer → ScheduleStore.upsert(...)
   ▼
ScheduleStore.shared (⭐ singleton : SEUL écrivain de schedules.json)
   │                                    │
   │  écrit (atomique)                  │  installe
   ▼                                    ▼
~/Library/Application Support/     SchedulerService.shared
  PotofToolkit/scheduler/            │  bootout → enable → bootstrap
    schedules.json                   ▼
                                   ~/Library/LaunchAgents/
                                     com.potof.toolkit.schedule.<uuid>.plist
                                        │
                                        │  à l'heure dite (ou « Lancer maintenant »)
                                        ▼
                        potof-toolkit --run-schedule <uuid>
                        (mode HEADLESS, avant NSApplication — main.swift)
                                        │
                                        ▼
                                 ScheduleRunner
          verrou → dossier → préscript (PTY) → claude mcp list → settings du run
                 → session claude (PTY 120×40, hook Stop, /exit)
                                        │
             ┌──────────────────────────┼─────────────────────────┐
             ▼                          ▼                         ▼
   runs.jsonl (start/end)     logs/<runID>.tty (flux brut)   ScheduleNotifier
             │                          │
             │  tail (vnode)            │  tail (vnode) + TTYFileReader
             ▼                          ▼
   historique dans l'UI       onglet « Session » (TerminalView en lecture seule)
                                        │
                                        ▼  « Reprendre dans Claude Launcher »
                              claude --resume <sessionID>
```

Le prompt ne traverse **jamais** un shell ni un plist. `ProgramArguments` ne porte que
`["<binaire>", "--run-schedule", "<uuid>"]`. Le runner passe le prompt en argument
positionnel : `$SHELL -l -i +m -c 'exec claude "$@"' claude <args> -- <prompt>`. Le shell
reçoit `"$@"` tel quel, et `claude` lit le prompt après `--`. Un prompt qui contient `'`,
`$(…)`, des retours à la ligne ou qui commence par `-` arrive intact (`run.argvIntact`).

## Déroulé d'un run

```
 1. RunLog.start()                                (paire start/end toujours complète)
 2. désactivée et déclencheur ≠ manual            → skipped « planification désactivée »
 3. flock(LOCK_EX|LOCK_NB) par planification      → skipped « un run est déjà en cours »
 4. le dossier existe et c'est un dossier ?       → failed « dossier introuvable : <chemin> »
 5. préscript non vide → PTY, $SHELL -l -i +m -c  code ≠ 0 → failed « préscript en échec (code N) »
                                                  600 s    → failed « préscript : délai dépassé »
 6. MCP requis non vides → claude mcp list        indisponible → failed « MCP requis indisponibles : … »
                                                  90 s     → failed « claude mcp list : délai dépassé »
 7. settings du run = settings de la planif + hook Stop
                                                  illisible → failed « fichier de settings illisible : … »
 8. session claude dans le PTY (délai = timeoutMinutes)
       hook Stop vu puis /exit          → completed « session terminée »
       sortie sans hook Stop            → failed « claude s'est arrêté avant la fin de sa réponse (code N) »
       sortie 127 (exec impossible)     → failed « claude introuvable ou non exécutable (code 127) »
       délai dépassé                    → timedOut « délai de N min dépassé »
       dialogue de confiance            → failed « dossier non approuvé par Claude : ouvrez-le une fois dans Claude Launcher »
       fork impossible                  → failed « lancement impossible »
 9. échec, skip ou délai sous launchd → bannière (ScheduleNotifier), APRÈS la ligne `end`
```

Ces messages sont vérifiés au mot près par `--sched-selftest run`. Le `.tty` reçoit un
bandeau `── préscript ──` puis `── claude ──` : la vue « Session » montre les deux.

Le `sessionID` est un UUID neuf par run, **toujours en minuscules**. Il est imposé à
`claude` par `--session-id`, écrit dans la ligne `end` dès l'étape 8, et sert à retrouver
la conversation (`~/.claude/projects/<dossier encodé>/<sessionID>.jsonl`).

### Le préscript

Facultatif. Exécuté dans le dossier par `$SHELL -l -i +m -c`, dans le même PTY enregistré
que la session. Il sert à préparer le dossier : `git pull`, un `npm install`, un export.
**Il est attendu jusqu'au bout.** Un code ≠ 0 ou un délai dépassé (600 s, fixe) fait
échouer le run, et `claude` n'est **pas** lancé : une session ne part pas sur un dossier à
moitié préparé. Un préscript qui attend une saisie (git qui demande un mot de passe) finit
donc en `failed` au bout du délai (`run.preScriptHangs`).

`$SHELL` n'est retenu que si c'est zsh, bash ou sh ; sinon `/bin/zsh`. Le login shell
interactif (`-l -i`) recharge le PATH des rc, comme les sessions de Claude Launcher.

⚠️ **Le shell tourne SANS contrôle de jobs** (`+m` à l'invocation, `set +m;` en tête de la
commande). Un shell interactif en active un : chaque commande, chaque job de fond
(`npm run dev &`) et chaque pipeline (`claude mcp list | cat`) partirait alors dans son
**propre groupe de process**, hors d'atteinte de `kill(-pid, …)`. Le délai dépassé aurait
fini le run en `failed` en laissant le serveur orphelin, indéfiniment. Mesuré : `+m` suffit
à zsh, mais **bash et sh l'ignorent quand `-i` est présent** — d'où le `set +m;` en tête,
que ni les rc ni l'invocation ne peuvent défaire avant lui. Vérifié par
`pty.killsBackgroundJob.zsh` / `.bash` (shell interactif, job de fond, délai 1 s : le job
doit être mort). La session `claude` n'est pas concernée : `exec` en fait le chef de session.

### La session : un PTY 120×40 possédé par le runner

`PTYProcess` lance la commande par `PseudoTerminalHelpers.fork` (SwiftTerm, sans vue) dans
une grille **fixe de 120 colonnes × 40 lignes**. La GUI rejoue le flux dans un
`TerminalView` qui garde **toujours 120 colonnes** : un autre nombre ferait mal rendre un
TUI dessiné pour 120 colonnes. Pour occuper toute la largeur du panneau, c'est la **police**
qui suit la largeur : à chaque changement, la vue reconstruit un terminal neuf et rejoue le
`.tty` depuis le début, car changer la police d'un terminal déjà rempli ferait re-découper
son contenu. La **hauteur** donne le nombre de lignes, et en changer ne re-découpe rien.
Rien n'est mis à l'échelle (SwiftTerm dessine sur un calque, un agrandissement serait
flou), et il n'y a pas de `ScrollView` autour : elle ajoutait une 2ᵉ barre verticale à celle
de l'historique du terminal.

`forkpty` fait de l'enfant le chef de session et de son groupe. Tous les signaux visent le
**groupe** (`kill(-pid, …)`), petits-enfants compris (`pty.killsGroup`). Arrêt gradué :
SIGTERM, puis SIGKILL après 3 s.

Une session interactive **ne se termine pas d'elle-même** : elle reste au prompt après sa
réponse. La fin se décide ainsi :

1. Le runner écrit `logs/<runID>.settings.json` : les settings de la planification
   (facultatifs, objet JSON obligatoire), plus **en fin** de `hooks.Stop` un hook
   `touch '<logs/<runID>.stop>'`. Les hooks `Stop` de l'utilisateur restent intacts. Il
   impose aussi `"tui": "default"`, même si le fichier demande autre chose : en
   `fullscreen`, `claude` dessine sur l'écran alternatif et le quitte à `/exit`, et le rejeu
   d'un run fini ne montrait plus que « Resume this session with… » (vu en recette le
   2026-10-30).
2. Quand le marqueur apparaît, le runner écrit `/exit\r` dans le PTY. Si la session n'est
   pas sortie 10 s plus tard, il tue le groupe. Fin `completed` dans les deux cas.
3. Sans marqueur, le délai de la planification (`timeoutMinutes`, 1…240, défaut 60) tue le
   groupe. Fin `timedOut`, `.tty` conservé.

### Le dialogue de confiance

Dans un dossier que `claude` n'a jamais approuvé, la session reste bloquée sur « Do you
trust this folder? ». Personne n'est là pour répondre. Le runner examine les 64 premiers
Ko du flux : séquences d'échappement retirées, blancs retirés, minuscules, recherche de
`trustthisfolder`. Le TUI espace ses mots par des déplacements de curseur (`ESC [ 1 C`),
pas par des espaces : d'où le retrait des blancs. Trouvé ⇒ groupe tué, run `failed` en
quelques secondes (`run.untrusted`), et la vue « Session » montre le dialogue.

Le remède est manuel : ouvrir le dossier une fois dans Claude Launcher et accepter.
L'approbation vit dans `~/.claude.json` (`projects[<chemin>].hasTrustDialogAccepted`). Le
formulaire et la simulation la lisent (`ClaudeInvocation.isTrusted`) pour **avertir**, sans
bloquer : seule la détection dans le PTY fait foi. Les dossiers parents ne comptent pas.

### `dontAsk`, pont IDE coupé, environnement nettoyé

Personne n'est devant l'écran pendant un run. Deux réglages en découlent, **toujours** :

- **`--permission-mode dontAsk`** — jamais `bypassPermissions` ni `acceptEdits`. Un prompt
  de permission figerait la session jusqu'au délai ; `dontAsk` refuse ce que les settings
  n'autorisent pas, et le run continue. Ce qui doit être permis se déclare dans le fichier
  de settings de la planification (`permissions.allow`).
- **`CLAUDE_CODE_AUTO_CONNECT_IDE=false`** — sinon `claude` s'auto-connecterait au pont IDE
  de Potof, et un `openDiff` bloquant ouvrirait la fenêtre de revue sans personne pour y
  répondre. C'est la première condition testée par `claude` 2.1.314.

L'environnement de la session (`ClaudeInvocation.environment`) part de celui du runner,
puis :

| Retiré | Pourquoi |
|---|---|
| toute clé `CLAUDE_CODE_*` héritée | `CLAUDE_CODE_SSE_PORT` brancherait la session sur un port IDE mort ; `CLAUDE_CODE_CHILD_SESSION` (hérité quand on teste depuis une session Claude) empêche d'enregistrer la conversation, donc toute reprise |
| `CLAUDECODE` | même famille : marqueur de session parente |
| `POTOF_SESSION_ID` | clé des notifications : héritée, elle attribuerait les événements du run à une session Potof sans rapport |

| Posé | Valeur |
|---|---|
| `TERM` / `COLORTERM` | `xterm-256color` / `truecolor` |
| `CLAUDE_CODE_AUTO_CONNECT_IDE` | `false` (posé après le retrait des `CLAUDE_CODE_*`) |
| `LANG` | `en_US.UTF-8`, seulement s'il est absent |

Le shell de login peut redonner une de ces variables si un rc la pose : c'est voulu, le
runner ne réécrit pas les rc de l'utilisateur.

### Les MCP requis : `claude mcp list`

Certaines planifications n'ont aucun sens sans un MCP (le rapport Sentry sans Sentry). Chaque
planification liste donc ses **MCP requis**. Avant la session, le runner lance
`claude mcp list` dans le même shell de login et le même dossier, avec 90 s de délai, et
échoue en nommant chaque MCP manquant : `nom (needs-auth)`, `nom (échec : …)`,
`nom (absent)`.

**Ce n'est pas `-p` qui fait foi.** En `claude -p`, le plugin Sentry disparaît, supplanté par
le connecteur « claude.ai Sentry » jamais autorisé (réglé hors dépôt par `deniedMcpServers`
dans `~/.claude/settings.json`). En session interactive, le plugin est gardé. `mcp list` est
donc le contrôle qui reflète ce qu'aura la session.

⚠️ `claude mcp list` tourne avec sa sortie sur un **tube** (`… mcp list | cat`, avec
`pipefail`), pas sur le PTY. Mesuré le 2026-10-30 : face à un terminal, il remplace les
espaces par des déplacements de curseur, coupe les lignes à la largeur de la grille et
réécrit ses premières lignes — illisible pour `MCPList.parse`. Sur un tube, il imprime des
lignes simples.

### « Lancer maintenant » est détaché

`ScheduleStore.runNow` lance le binaire de l'app (`--run-schedule <uuid>`, environnement
hérité + `POTOF_SCHEDULE_TRIGGER=manual`) comme un process **détaché**, sans tube. On
n'attend pas sa fin : le tail de `runs.jsonl` et du `.tty` met l'UI à jour. Conséquence
voulue : **quitter Potof n'interrompt pas un run**, qui écrit sa ligne `end` tout seul. Un
run manuel ne poste pas de bannière : l'utilisateur regarde déjà l'écran.

Sur une planification désactivée, « Lancer maintenant » part quand même : c'est un geste
explicite. Le verrou par planification exclut un tir launchd simultané.

### Voir et reprendre

L'onglet **« Session »** rejoue le `.tty` du run choisi dans un `TerminalView` SwiftTerm
(pas `LocalProcessTerminalView` : aucun process côté GUI). Lecture seule : saisie jetée,
souris non rapportée. Un `DispatchSource` vnode suit le fichier, et `TTYFileReader` ne lit
que la suite depuis le dernier décalage, **par tranches de 256 Ko** (`pty.readerSliced`) :
le fichier n'est jamais chargé d'un bloc, et le runloop reprend la main entre deux
tranches, donc une session de plusieurs dizaines de Mo ne fige pas la fenêtre. Un run
terminé se relit de la même façon, sans rien surveiller.

Tant que le run est en cours et que le `.tty` n'existe pas encore (il naît au premier
octet), la vue réessaie toutes les 0,5 s. Dès que le run n'est plus « en cours », les
réessais s'arrêtent ; s'il n'y a toujours pas de `.tty` (échec avant le préscript et
`claude`), la vue affiche « Aucune session enregistrée pour ce run. ». L'onglet
s'affiche par défaut quand un run tourne ; un clic dans l'historique y ouvre le run choisi.

**« Reprendre dans Claude Launcher »** ouvre `claude --resume <sessionID>` dans le dossier
et bascule d'outil. Le bouton est grisé, avec la raison au survol, quand le run tourne
encore ou quand la conversation `<sessionID>.jsonl` est introuvable (run arrêté avant
l'étape 8). On ne saisit jamais dans la session pendant le run : on la reprend après.

## Les fichiers

```
~/Library/Application Support/PotofToolkit/scheduler/
├── schedules.json                  ← source de vérité (v2). Écrite UNIQUEMENT par la GUI, atomiquement.
├── runs.jsonl                      ← historique append-only. Écrit par la GUI ET par le headless.
├── logs/<runID>.log                ← journal détaillé du run
├── logs/<runID>.tty                ← flux brut du PTY (préscript puis session), rejoué par la GUI
├── logs/<runID>.settings.json      ← settings passés à claude --settings
├── logs/<runID>.stop               ← marqueur posé par le hook Stop
└── locks/<scheduleID>.lock
~/Library/Logs/PotofToolkit/schedule-<uuid>.out.log   ← StandardOutPath du job
~/Library/LaunchAgents/com.potof.toolkit.schedule.<uuid>.plist
```

Aucune purge des fichiers de `logs/` pour l'instant : à revoir si le dossier grossit.

**Pourquoi des fichiers et pas `UserDefaults`.** `UserDefaults` ne notifie pas de façon
fiable les écritures d'un **autre process** : l'historique et la session en direct seraient
impossibles. Et une lecture-modification-écriture sur un tableau perdrait des données quand
la GUI édite pendant qu'un run headless écrit.

### L'invariant qui supprime toute une classe de bugs

> **`schedules.json` a un seul écrivain : la GUI. Le mode headless est lecteur seul, et
> unique écrivain de sa portion du JSONL.**

Corollaire visible dans le modèle : **il n'y a pas de `lastRunAt` dans `Schedule`**. La
date du dernier run est **dérivée** de `runs.jsonl`. Sans ça, il faudrait arbitrer des
courses entre deux process.

### `schedules.json` v2

`SchedulesFile.currentVersion = 2`. `Action` est encodé à la main avec un discriminant
`"kind" : "claude"`. À la lecture :

| État du fichier | Effet |
|---|---|
| absent | liste vide |
| v2 | chargé |
| **v1** (Superset Scheduler) | liste vide, et la GUI réécrit un v2 vide. Suppression décidée le 2026-10-30 ([ADR 0001](adr/0001-scheduler-claude-vanilla-sans-ide.md)) |
| illisible | liste vide, **rien n'est réécrit**, bandeau d'erreur |

Le headless lit par le statique `ScheduleStore.loadFromDisk()` et ne réécrit jamais rien.

### `runs.jsonl` — deux lignes par run

```json
{"at":"…","phase":"start","pid":41207,"runID":"…","scheduleID":"…","trigger":"launchd","v":2}
{"at":"…","message":"session terminée","phase":"end","runID":"…","sessionID":"…","status":"completed",…,"v":2}
```

Deux lignes plutôt qu'une écrite à la fin : une ligne est **toujours complète** quand elle
est écrite ; un run en cours est visible immédiatement ; un run interrompu (crash, reboot)
se lit tout seul — `start` sans `end` avec un pid mort ⇒ `interrupted`. Les lignes v1
(statut `launched`) ne se décodent plus et sont sautées.

`status` ∈ `completed` | `failed` | `skipped` | `timedOut`, plus `running` et
`interrupted`, **dérivés** par le pliage et jamais écrits. **`skipped` n'est pas un
échec** : c'est un garde-fou qui a joué. L'UI le montre en orange, `failed` en rouge — les
confondre revient à crier au loup tous les jours jusqu'à ne plus regarder. `timedOut` a sa
propre pastille : la session tournait encore, elle a été tuée.

Écriture : `open(O_WRONLY|O_CREAT|O_APPEND)` → `flock(LOCK_EX)` → **un seul** `write` →
`flock(LOCK_UN)` → `close`. D'où le plafond de 500 caractères sur `message` et
l'interdiction d'y mettre un corps de log (il va dans `logs/<runID>.log`, le flux du
terminal dans `logs/<runID>.tty`).

**Compaction** : au lancement de la GUI seulement, au-delà de 2 Mo, on garde les 1 000
dernières lignes par réécriture **en place** (`ftruncate`). ⚠️ **Jamais de `rename`** — ça
changerait l'inode sous le nez d'un appender ayant déjà son `fd` ouvert, et ses runs
disparaîtraient sans un bruit.

## Périodicité → `StartCalendarInterval`

Règle du man : *« Missing arguments are considered to be wildcard »*. On n'émet **que** les
clés qui contraignent.

| Cadence | Intervalles émis |
|---|---|
| `everyNHours(6, ancre 2, min 0)` | `[{Hour:2},{Hour:8},{Hour:14},{Hour:20}]` (+`Minute`) |
| `daily(10, 0)` | `[{Hour:10, Minute:0}]` |
| `weekly({1..5}, 10, 0)` | une entrée `Weekday` par jour ; **7 jours ⇒ une seule entrée sans `Weekday`** |
| `monthly(1, 9, 30)` | `[{Day:1, Hour:9, Minute:30}]` |

### Les cinq pièges, tous vérifiés

1. **Un dictionnaire vide vaut « toutes les minutes ».** Corollaire de la règle du joker :
   un dict sans aucune clé ne contraint rien. Le cas « aucun jour coché » se rend donc par
   un **tableau vide** (aucune occurrence), jamais par un dict vide. Toute entrée émise
   porte au minimum `Hour` + `Minute`.
2. **`Day` + `Weekday`, c'est un OU** (*« the job will be started if either one matches »*).
   Un mensuel qui émettrait `Weekday` par inadvertance tirerait **une fois par semaine en
   plus**. Invariant à vérifier en premier : `calendarIntervals(for: .monthly(…))` ne
   contient jamais la clé `Weekday`.
3. **launchd ne clampe pas.** `Day: 31` ne se déclenche jamais en février, avril, juin,
   septembre ni novembre — silencieusement. D'où le plafond à **28**.
4. **Jamais `StartInterval`.** C'est un minuteur relatif à la mise en charge : il redémarre
   son compteur à chaque login **et à chaque réinstallation du plist** (donc à chaque
   édition), il dérive de la durée du run à chaque cycle, et il ignore l'heure de la
   journée. Le man est explicite : *« StartInterval and StartCalendarInterval are not aware
   of each other »* — les mélanger produirait deux planificateurs indépendants.
5. **Un intervalle non-diviseur de 24 n'a aucune expression calendaire.** 5, 7, 9 h : le
   motif ne se referme pas sur 24 h. L'UI ne propose que `[1, 2, 3, 4, 6, 8, 12]`.

### Deux conversions à ne pas rater

- **Jours de semaine** : launchd indexe `0 = dimanche … 6 = samedi` (et accepte `7` pour
  dimanche). `Calendar`, lui, indexe `1 = dimanche … 7 = samedi`. Se tromper produit une
  **UI qui promet le mauvais jour alors que le plist est correct** — divergence
  parfaitement silencieuse. La conversion vit dans `LaunchAgentPlist`, nulle part ailleurs.
- **`RunAtLoad => 0`** dans `plutil -p` est la bonne sortie, pas un typage raté : c'est
  `<false/>` en XML.

### Le plist

Généré par `PropertyListSerialization.data(fromPropertyList:format:.xml)` — **jamais** de
template de chaîne.

- **`RunAtLoad = false` impérativement.** `bootstrap` a lieu à chaque ouverture de session
  **et** à chaque réinstallation du plist. `true` lancerait une session à chaque login et à
  chaque clic sur Enregistrer. **Ce n'est pas un mécanisme de rattrapage** — c'est le
  contresens à ne pas faire.
- **Pas de `KeepAlive`** : un run qui échoue ne doit surtout pas être relancé en boucle.
- launchd **ne développe pas `$HOME`** dans `EnvironmentVariables` : chemins littéraux
  absolus, construits depuis `NSHomeDirectory()`.
- Le PATH par défaut sous launchd est `/usr/bin:/bin:/usr/sbin:/sbin`. Le plist pose un
  plancher (`~/.local/bin`, où l'installeur natif pose `claude`, puis Homebrew et le
  système) ; le shell de login du runner recharge ensuite le PATH complet des rc.
- `POTOF_SCHEDULE_TRIGGER=launchd` dans `EnvironmentVariables` : c'est ce qui distingue un
  tir launchd d'un run manuel (`manual`) ou lancé depuis un terminal (`cli`).

### `bootstrap` / `bootout`, pas `load` / `unload`

```
install : createDirectory(logs) → écriture atomique → bootout → enable → bootstrap
remove  : bootout → suppression du plist
status  : launchctl print gui/<uid>/<label>     # exit 0 = chargé
```

- **Réécrire le fichier ne recharge rien** : le job chargé garde en mémoire l'ancienne
  définition. `bootout` + `bootstrap` sont obligatoires à **chaque** modification.
- Le `bootout` en amont est **toléré en échec** : à la première installation il rend
  **3** (ESRCH, mesuré) ou **113** (« Could not find specified service »). Les traiter en
  échec rendrait toute installation impossible.
- **L'étape `enable` n'est pas décorative** : `launchctl disable` écrit dans une base **par
  utilisateur qui survit à `bootout`/`bootstrap`**. Sans elle, un job désactivé une fois
  resterait muet pour toujours, plist parfaitement valide à l'appui.

### Sommeil, extinction, rattrapage

| Situation | Comportement | Ce qu'on fait |
|---|---|---|
| Mac **endormi** à l'heure dite | le job démarre **au réveil**, occurrences manquées coalescées en une seule | rien |
| On voudrait **réveiller** la machine | `StartCalendarInterval` ne réveille pas | hors périmètre (ce serait `pmset repeat`) |
| Mac **éteint** / session fermée | le domaine `gui/<uid>` n'existe pas, occurrences **perdues** | on ne relance jamais tout seul |

Pas d'auto-rattrapage : après une semaine de vacances, il lancerait N sessions simultanées
dans le même dossier. Et rejouer la veille de mardi dernier n'a aucun sens métier.

> ⚠️ **L'angle mort : un Mac éteint ne laisse AUCUNE trace.** Mesuré le 2026-08-31 avec
> l'ancien outil : Mac éteint trois semaines, environ 13 occurrences ouvrées perdues, et
> pas une ligne `skipped`, pas une bannière, pas un bandeau d'audit. Le trou ne se voyait
> qu'à la date du dernier livrable. C'est toujours vrai : rien ne contrôle la **fraîcheur**
> des runs (« aucun `completed` depuis N jours alors que la planification est active »).
> Une veille qui calcule sa fenêtre depuis son propre dernier livrable re-couvrira le trou
> au run suivant, mais personne n'aura été averti.

## Notifications

`ScheduleNotifier.post(...)` — `UserNotifications`, depuis le runner, **uniquement** sur
`failed`, `skipped` ou `timedOut`, et **uniquement** si `POTOF_SCHEDULE_TRIGGER == launchd`
(« Lancer maintenant » n'a rien à notifier, l'utilisateur regarde déjà l'écran). Le titre
distingue les cas : « run sauté », « délai dépassé », « échec ». Appelée **après**
l'écriture de la ligne `end` : un canal de notification défaillant ne doit jamais coûter la
trace du run. Le sort de la bannière est lui-même consigné dans le log du run.

Pourquoi pas le canal interne de la cloche : `ChannelEvent.potofSessionId` est
non-optionnel (le runner n'a pas de session Potof), et surtout `NotificationChannel.start()`
fait un `O_TRUNC` — une notif écrite app fermée serait effacée à l'ouverture suivante. Or
« app fermée » est le cas **nominal** d'un job de 10:00.

### ⚠️ Pourquoi pas `osascript`

C'était la première implémentation, calquée sur les scripts bash du poste. **Mesuré : elle
ne délivre rien.** Quatre runs launchd conclus en `skipped` ont appelé `/usr/bin/osascript`
avec un **code de sortie 0**, sans qu'aucune bannière n'apparaisse. Un `display
notification` émis par le binaire `osascript` n'a pas d'identité d'app enregistrée, et
macOS le jette en silence. L'`exit 0` ne prouvait donc rien, ce qui rendait la panne
indétectable.

⚠️ **Un argument d'appui de cette section était faux, ne pas le reprendre.** Il était écrit
ici que « Script Editor ne figure même pas dans les réglages de notification du poste ».
Mesuré le 2026-08-11 : `com.apple.ScriptEditor2` **est** bien présent dans
`~/Library/Preferences/com.apple.ncprefs.plist`
(`plutil -convert xml1 -o - ~/Library/Preferences/com.apple.ncprefs.plist`), avec son
chemin `/System/Applications/Utilities/Script Editor.app` et une exigence de source
`com.apple.osascript`. La conclusion tient — elle est même **plus dure** : figurer dans les
réglages ne suffit pas, la bannière tombe quand même. C'est l'identité de l'**appelant**
qui manque, pas une entrée de préférences.

L'identité correcte était disponible depuis le début : l'app **est** enregistrée
(`com.potof.potof-toolkit`) puisqu'elle pose déjà des bannières pour les sessions Claude.
Sous launchd, le runner s'exécute depuis `…/Potof Toolkit.app/Contents/MacOS/`, il porte
donc ce bundle. D'où `ScheduleNotifier`, isolé dans son fichier : `UserNotifications` n'est
ni AppKit ni SwiftUI, l'importer là ne met pas en péril la garantie structurelle de
`ScheduleRunner` (qui, lui, n'importe que `Foundation`).

⚠️ La garde `canPost` (= `pathExtension == "app"`, même garde que `canUseUN`) est
obligatoire : `UNUserNotificationCenter` **plante** sur un binaire nu, donc en `swift run`.

### Mais « osascript est muet » ≠ « bash ne peut pas notifier »

À ne pas re-conclure à l'envers, parce que le raccourci coûte un aller-retour : il existe un
canal qui fonctionne côté script. Cinq variantes mesurées le 2026-08-11, **présence à
l'écran confirmée** :

| Variante | Code retour | Bannière |
|---|---|---|
| `osascript` nu | 0 | non |
| via `System Events` | 0 | non |
| via `Script Editor` | 0 | non |
| via `Finder` | **1** (`-1743`) | non |
| **`terminal-notifier`** | 0 | **OUI** |

`terminal-notifier` délivre parce qu'il porte **sa propre identité d'app** — il embarque son
`.app`, déjà autorisé dans les réglages de notification.

En une ligne, la règle des deux mondes : **côté bash `terminal-notifier`, côté app
`UNUserNotificationCenter`, et dans les deux cas le code de retour d'`osascript` n'est
JAMAIS une preuve d'affichage.**

## Le mode headless et sa liste noire

`main.swift` reconnaît `--run-schedule` **avant** `NSApplication`, comme `--ide-selftest`.
`ScheduleRunner` n'importe que `Foundation` : avec ce seul import, `NSApp` devient une
**erreur de compilation**. Ce n'est pas une convention, c'est une garantie structurelle.
`PTYProcess` importe SwiftTerm, mais n'en utilise que `PseudoTerminalHelpers` : aucune vue.

Le runner ne doit réveiller **aucun** de ces singletons (tous lazy, donc inertes tant qu'on
n'y touche pas) :

| Singleton | Ce qui casserait |
|---|---|
| `NotificationCenterCoordinator.shared` | son `start()` fait `open(…, O_TRUNC)` sur `notifications.jsonl` → **effacerait le canal de la GUI en cours**. Le plus vicieux. |
| `IDEHost.shared` | prend le lock `~/.claude/ide/<port>.lock` sur tout `$HOME` → deux IDE « valides » ⇒ plus aucune auto-connexion, des deux côtés |
| `IDELog.startSession()` | tronque `ide.log` de l'app vivante |
| `SessionStore` / `ScriptRunStore` / `*TerminalController` | tirent les vues SwiftTerm, aucun intérêt |
| `Bundle.module` | `fatalError` en contexte bundlé |

C'est pour ça que le runner passe par le **statique** `ScheduleStore.loadFromDisk()`, qui
n'instancie rien et n'arme aucune surveillance.

### Refus d'installer hors `.app`

`canInstallLaunchAgents` = `Bundle.main.bundleURL.pathExtension == "app"`, exactement la
même garde que `canUseUN`. En `swift run`, le binaire vit dans `.build/debug/` — chemin
éphémère qu'un `swift package clean` efface. Un plist pointant là serait mort au premier
nettoyage, **sans le moindre signal**. En dev, le formulaire, l'historique et « Lancer
maintenant » fonctionnent ; l'activation est grisée et l'UI dit pourquoi.

Conséquence : **`audit()` rend `[]` en dev**. Sinon toutes les planifications créées par
l'app bundlée remonteraient en `pathMismatch` — un bandeau intégralement faux.

## Écrire dans `~/Library/LaunchAgents` — la règle non négociable

Ce dossier permet d'exécuter du code arbitraire à l'ouverture de session. On ne
supprime/écrase un fichier **que si** :

1. son nom est `com.potof.toolkit.schedule.<uuid>.plist`, **ET**
2. son `ProgramArguments[0]` se termine par `/potof-toolkit`.

**Jamais de suppression par glob.** Un bug de préfixe qui effacerait le plist d'un autre
éditeur serait irréparable côté utilisateur.

Corollaire assumé : un fichier portant notre nom mais **illisible** (plist corrompu) n'est
pas « le nôtre » — on refuse de l'écraser, on dit lequel et pourquoi, et la seule issue est
manuelle. Les plists laissés par des planifications v1 supprimées deviennent des orphelins
que l'audit propose de purger.

## Débogage

```bash
potof-toolkit --run-schedule <uuid> --dry-run              # plan complet, AUCUN effet de bord
potof-toolkit --sched-selftest pty | claude | plist | store | run
potof-toolkit --sched-selftest live <dossier approuvé>     # opt-in : VRAI claude (haiku, ~0,01 $)
```

Le binaire n'est **pas sur le `PATH`** : ces commandes s'appellent par chemin explicite,
`~/Applications/Potof\ Toolkit.app/Contents/MacOS/potof-toolkit` (ou `.build/debug/` en dev
— où l'installation de LaunchAgents est refusée, voir « Refus d'installer hors `.app` »).
Les probes travaillent sous `SchedulePaths.overrideRoot` : le vrai dossier du scheduler et
`~/Library/LaunchAgents` restent inchangés. Elles sortent avant `NSApplication`.

La probe `run` remplace `claude` par un faux script sh et couvre chaque issue du déroulé.
La probe `live` lance le vrai `claude` sur « Réponds juste OK » et vérifie aussi que la
conversation est enregistrée — ce qui prouve que `CLAUDE_CODE_CHILD_SESSION` est bien
retiré, puisqu'on la lance depuis une session Claude.

Le `--dry-run` (bouton **« Simuler le prochain run »**, onglet **« Plan »**) ne lance aucun
PTY ni pour le préscript ni pour la session. Il imprime : le dossier (existe ? approuvé ?),
le préscript, le résultat **réel** de `claude mcp list` (lecture seule), l'argv exact de la
session avec un `sessionID` d'exemple (un argument par ligne), le prompt intégral et le
`.plist` qui serait installé. Il conclut `skipped`.

⚠️ **Un garde-fou qui se déclenche est ANNOTÉ, il n'interrompt pas le plan**
(`⚠︎ un run réel s'arrêterait ici : …`), et le verdict final reflète ce qu'un run réel
aurait fait. Sans ça, l'outil de debug ne montrerait rien le jour où il y a justement
quelque chose à comprendre. Un dry-run n'écrit **aucune** ligne d'historique et ne pose
**aucun** verrou. Depuis l'app, il simule le déclencheur `launchd` (et non `manual`) : le
runner traite une planification désactivée différemment selon le déclencheur.

> ⚠️ **Un argument inconnu démarre une SECONDE INSTANCE de l'app.** Seul `--help` / `-h` en
> **première** position est intercepté (`App/CLIHelp.swift`, pur, testable au `swiftc`
> sans lancer l'app). L'ancrage sur le premier argument n'est pas cosmétique : un
> `contains("-h")` sur tout l'argv faisait sortir `--sched-selftest -h` en 0 sans exécuter
> la probe, un faux vert. Les autres arguments inconnus tombent toujours dans la GUI ; les
> rejeter exige une liste blanche des arguments que macOS passe lui-même (`-psn_0_…`,
> `-NSDocumentRevisionsDebugMode`, `-AppleLanguages`).

### ⚠️ Pourquoi il n'y a pas de « tester le déclencheur launchd »

Il y en a eu un. Il faisait `launchctl kickstart -k gui/<uid>/<label>` et se présentait
comme un diagnostic. **C'était un run réel** : launchd exécute le `ProgramArguments` du
plist, c'est-à-dire `--run-schedule <uuid>` **sans** `--dry-run`. En trois clics il a lancé
deux agents payants.

Et ce n'est pas rattrapable : le plist fige son argv, délibérément (aucun texte utilisateur
dans `~/Library/LaunchAgents`), donc **on ne peut pas demander à launchd une simulation**.
Le bouton a été supprimé, pas renommé — même raisonnement que `confirmEditInTerminal`
dans le pont IDE : une affordance qui ment sur son effet ne se corrige pas par un meilleur
libellé. `isLoaded(_:)` répond sans rien déclencher à la seule question que le kickstart
tranchait vraiment (« le job est-il chargé ? »), et le bandeau d'audit la pose tout seul.

**`ScheduleStore.runNow` est le seul chemin de l'UI qui lance un run réel.**

## Désinstallation

L'app est le seul réparateur : si elle est supprimée, ses plists restent et échouent
perpétuellement. Avant de la désinstaller, supprimer les planifications depuis l'outil.
À la main :

```bash
LABEL=com.potof.toolkit.schedule.<uuid>
launchctl bootout gui/$(id -u)/$LABEL
rm ~/Library/LaunchAgents/$LABEL.plist
rm -rf ~/Library/Application\ Support/PotofToolkit/scheduler
```

## Limites connues

- **Faux positif du dialogue de confiance.** La détection cherche `trustthisfolder` dans
  les 64 premiers Ko du flux, blancs et casse ignorés, écho du prompt par le TUI compris :
  un prompt (ou un début de réponse) qui contient « trust this folder » tue la session et
  finit en `failed « dossier non approuvé… »`, un message trompeur. Non corrigé.

## Hors périmètre

- Saisie dans la session pendant le run : la vue est en lecture seule, on reprend dans
  Claude Launcher.
- Coût et nombre de tours par run : pas de résultat JSON en interactif.
- Rétention et purge des `.tty`, `.stop`, `.settings.json`.
- Contrôle de fraîcheur des runs · vérification du livrable · jetons de substitution dans
  le prompt · réveil de la machine (`pmset`) · « dernier jour du mois » · intervalle
  non-diviseur de 24 · rattrapage automatique.
- Pilotage des automations Orca existantes.
