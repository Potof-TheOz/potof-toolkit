# Superset Scheduler — lancer des agents à heure fixe

Quatrième outil du toolkit : on saisit un prompt, un agent, une périodicité et une cible,
et l'app génère puis entretient un **job launchd** qui rappelle son propre binaire en mode
**headless** pour lancer un agent Superset.

> **Ce que l'outil garantit, et rien de plus : le lancement.** Un run réussi signifie
> « `superset agents create` a rendu 0 », pas « le travail a été fait ». C'est pour ça que
> le statut de succès s'appelle `launched` et **jamais** `ok` : un historique tout vert ne
> prouve que la mise à feu. La vérification du livrable est du métier, elle reste hors de
> cet outil (voir « Ce que le Superset Scheduler ne fait pas »).

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
                                        │  à l'heure dite, launchd exec :
                                        ▼
                        potof-toolkit --run-schedule <uuid>
                        (mode HEADLESS, avant NSApplication — main.swift)
                                        │
                                        ▼
                                 ScheduleRunner.execute
                    verrou → host service → cible → gardes → agents create
                                        │
                     ┌──────────────────┴──────────────────┐
                     ▼                                     ▼
             runs.jsonl (append-only)         ScheduleNotifier (échec/skip)
                     │
                     │  tail (DispatchSource vnode, SANS O_TRUNC)
                     ▼
             ScheduleStore.runs → historique vivant dans l'UI
```

Le prompt ne traverse **jamais** de shell ni de plist : `ProgramArguments` ne porte que
`["<binaire>", "--run-schedule", "<uuid>"]`, et la CLI est appelée avec
`arguments: [String]` (aucun échappement, donc aucune injection possible).

## Ce que le Superset Scheduler ne fait pas

C'est la partie la plus utile de cette doc, parce que le poste porte quatre automations
`com.potof.*` et que **l'outil n'en remplace qu'une, partiellement** :

| Automation | Forme | Reprise ? |
|---|---|---|
| `superset-daily-sentry.sh` | `superset agents create` | **le lancement seulement** |
| `knowledge-garden.sh` | un agent `claude -p` **par note échue**, chien de garde TERM/KILL | non |
| `sentry-daily-collect.sh` | vérifie le livrable, promeut un point de reprise | non |
| `knowledge-sync.sh` | git pur (commit par pathspec), aucun agent | non |

Trois de ces quatre portent leurs garde-fous **dans** le script. Les planifier reviendrait
à faire ce que launchd fait déjà. L'outil sert à créer la **prochaine** automation sans
réécrire 500 lignes de bash, pas à absorber celles qui existent.

**Le prompt est une chaîne littérale** : aucune substitution de jeton au lancement. Une
veille qui a besoin d'une fenêtre temporelle doit la faire calculer **par l'agent**
(« depuis le rapport le plus récent de tel dossier, celui du jour exclu ; à défaut les
24 dernières heures ; jamais au-delà de 30 jours »). C'est un choix assumé : le
planificateur ne connaît aucun métier.

## Les fichiers

```
~/Library/Application Support/PotofToolkit/scheduler/
├── schedules.json        ← source de vérité. Écrite UNIQUEMENT par la GUI, atomiquement.
├── runs.jsonl            ← historique append-only. Écrit par la GUI ET par le headless.
├── logs/<runID>.log      ← sortie détaillée d'un run
└── locks/<scheduleID>.lock
~/Library/Logs/PotofToolkit/schedule-<uuid>.out.log   ← StandardOutPath du job
~/Library/LaunchAgents/com.potof.toolkit.schedule.<uuid>.plist
```

**Pourquoi des fichiers et pas `UserDefaults`.** Pas pour l'histoire du domaine qui
diffère entre dev et bundlée (vrai, mais hors sujet : sous launchd, Foundation remonte
bien à l'enveloppe `.app`). Les vraies raisons : `UserDefaults` ne notifie pas de façon
fiable les écritures d'un **autre process**, donc l'historique live serait impossible ; et
une lecture-modification-écriture sur un tableau perdrait silencieusement des données
quand la GUI édite pendant qu'un run headless écrit.

### L'invariant qui supprime toute une classe de bugs

> **`schedules.json` a un seul écrivain : la GUI. Le mode headless est lecteur seul, et
> unique écrivain de sa portion du JSONL.**

Corollaire visible dans le modèle : **il n'y a pas de `lastRunAt` dans `Schedule`**. La
date du dernier run est **dérivée** de `runs.jsonl`. Sans ça, il faudrait arbitrer des
courses entre deux process.

### `runs.jsonl` — deux lignes par run

```json
{"at":"…","phase":"start","pid":41207,"runID":"…","scheduleID":"…","trigger":"launchd","v":1}
{"at":"…","message":"agent … lancé","phase":"end","runID":"…","status":"launched",…,"v":1}
```

Deux lignes plutôt qu'une écrite à la fin : une ligne est **toujours complète** quand elle
est écrite ; un run en cours est visible immédiatement ; un run interrompu (crash, reboot)
se lit tout seul — `start` sans `end` avec un pid mort ⇒ `interrupted`.

`status` ∈ `launched` | `failed` | `skipped` | `running` | `interrupted`.
**`skipped` n'est pas un échec** : c'est un garde-fou qui a joué. L'UI le montre en orange,
`failed` en rouge — les confondre revient à crier au loup tous les jours jusqu'à ne plus
regarder.

Écriture : `open(O_WRONLY|O_CREAT|O_APPEND)` → `flock(LOCK_EX)` → **un seul** `write` →
`flock(LOCK_UN)` → `close`. D'où le plafond de 500 caractères sur `message` et
l'interdiction d'y mettre un corps de log (il va dans `logs/<runID>.log`).

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
template de chaîne. (Il avale un `[String: Any]` Swift avec `Bool`/`Int`/`String` et des
conteneurs imbriqués, sans aucun pontage `NSNumber` manuel.)

- **`RunAtLoad = false` impérativement.** `bootstrap` a lieu à chaque ouverture de session
  **et** à chaque réinstallation du plist. `true` lancerait un agent à chaque login et à
  chaque clic sur Enregistrer. **Ce n'est pas un mécanisme de rattrapage** — c'est le
  contresens à ne pas faire.
- **Pas de `KeepAlive`** : un run qui échoue ne doit surtout pas être relancé en boucle.
- launchd **ne développe pas `$HOME`** dans `EnvironmentVariables` : chemins littéraux
  absolus, construits depuis `NSHomeDirectory()`.
- Le PATH par défaut sous launchd est `/usr/bin:/bin:/usr/sbin:/sbin`. Le plist pose donc
  un PATH complet — et `SupersetCLI` le repose lui-même, ceinture et bretelles.

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
| Mac **éteint** / session fermée | le domaine `gui/<uid>` n'existe pas, occurrences **perdues** | on **signale**, on ne relance jamais tout seul |

Pas d'auto-rattrapage : après une semaine de vacances, il lancerait N agents simultanés
dans le même worktree permanent — exactement ce que le garde-fou « agent vif » existe pour
éviter. Et rejouer une veille de mardi dernier n'a aucun sens métier.

## Déroulé d'un run

```
 1. argv → scheduleID, dryRun                          invalide → exit 64
 2. schedules.json → le schedule                       absent   → exit 66
 3. RunLog.start()                                     (paire start/end toujours complète)
 4. désactivée ? (sauf « Lancer maintenant »)          → skipped, exit 0
 5. flock(LOCK_EX|LOCK_NB)                    déjà pris → skipped, exit 0
 6. host service : status --json → open -g -a Superset → superset start --daemon
                                              injoignable → failed, exit 1
 7. résolution de la cible (voir ci-dessous)
 8. GARDE worktree : le dossier existe ?               absent → failed
 9. GARDE agent vif (workspace permanent seulement)    vivant → skipped
10. rafraîchissement PAR LE RUNNER (si demandé) :
       git fetch origin --prune ; git reset --hard origin/<base>   échec → failed
11. superset agents create …                           ≠ 0 → failed, exit 1
12. finish(.launched) + exit 0
13. échec/skip sous launchd → bannière (ScheduleNotifier), APRÈS la ligne `end`
```

Les points 7, 9, 10 et 12 sont repris du script de référence : ce sont des leçons payées en
production.

### Résolution de la cible — la règle qui évite le pire

> **On stocke les COORDONNÉES du workspace (`projectID` + `workspaceName`), jamais son
> `workspaceID`.** Un workspace supprimé puis recréé garde son nom et **change d'id** : la
> résolution se refait donc à chaque run.

> **Le matching se fait sur `(projectId, name)`, jamais sur le nom seul.** Mesuré sur ce
> poste : deux workspaces s'appellent « Sentry report », un par projet suivi — c'est
> normal, le script de référence a un `WS_NAME` constant et boucle sur les groupes. Un
> matching par nom seul ferait résoudre la planification « portal » vers le workspace
> « shopify ».

> ⚠️ **Mais `(projectId, name)` n'est pas non plus une clé unique : Superset accepte deux
> workspaces HOMONYMES dans le MÊME projet.** Constaté en recette. Deux conséquences, et
> les deux ont été des bugs réels :
>
> 1. **Après un `create`, on identifie le nouveau workspace par différence
>    d'identifiants**, jamais par son nom. Chercher par nom pouvait rendre un workspace
>    **préexistant** : l'agent partait dans le worktree de quelqu'un d'autre pendant que
>    celui qu'on venait de créer restait vide.
> 2. **Le nom d'un workspace neuf porte les SECONDES** (`<préfixe> AAAA-MM-JJ HH:mm:ss`).
>    À la minute, deux runs rapprochés — un « Lancer maintenant » cliqué deux fois —
>    fabriquaient deux workspaces au nom identique. Ne pas retirer les secondes.
>
> Et pour une cible **permanente**, si plusieurs workspaces portent le nom visé dans le
> projet, le run **abandonne en le disant** plutôt que d'en choisir un : faire travailler
> un agent dans un worktree que personne ne regarde est pire que ne rien faire.

> **`workspaces()` rend `nil` quand la liste est ILLISIBLE, ce qui n'est pas une liste
> vide.** Sur `nil`, le run **abandonne**. Créer à l'aveugle dupliquerait le workspace
> permanent — et la duplication n'est pas théorique.

On **ne parse jamais la sortie de `create`** : sa forme JSON n'est pas un contrat public.
On relit la liste, qui en est un. Une seule forme de données à connaître.

### `AgentPresence` — ce qu'il voit, et ce qu'il ne voit pas

Le garde-fou répond à « un agent `claude` travaille-t-il encore dans ce worktree ? » :
`pgrep -fl claude` → filtre sur le **premier token d'argv** → `lsof -a -p <pid> -d cwd -Fn`
→ comparaison après `resolvingSymlinksInPath().standardized` (`/private/var` contre `/var`).

Quatre faits mesurés :

- **La regex du script de référence est cassée** : `pgrep -f '/\.local/bin/claude$'` trouve
  un `claude` sans argument mais **manque** `claude --effort xhigh <prompt>` — dès qu'il y
  a des arguments, le `$` ne matche plus. Ne jamais ancrer sur la fin de la ligne d'argv.
- **`pgrep -fl` n'est pas une ligne par process** : un agent lancé avec un prompt multiligne
  étale ses arguments sur des dizaines de lignes. Le filtre robuste est « premier token
  entièrement numérique **et** deuxième token = exécutable `claude` reconnu ».
- **Trois formes d'`argv[0]`** coexistent : `~/.local/bin/claude` (shim),
  `~/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude`, et
  `~/.local/share/claude/versions/<version>` — d'où la condition `/claude/versions/`.
- **Limite à connaître** : la détection repose sur le **`cwd`** du process. Les agents
  lancés par `superset agents create` ont bien leur worktree comme `cwd` (vérifié), donc le
  garde-fou couvre le cas qu'il doit couvrir. Mais une session `claude` démarrée autrement
  — par exemple depuis `$HOME` puis naviguée — est **invisible** pour lui.

Et ce sur quoi on ne construit rien : **le champ `exited` des terminaux Superset ne dit pas
si l'agent a fini** — le shell survit à la sortie de `claude` et reste `exited: false` des
heures après. La mort du process est la seule condition qui fasse foi.

### « Pourquoi ne pas lancer quand même, dans un nouvel onglet ? »

Question posée, et **tranchée : non.** Techniquement `agents create` sait le faire — un
second appel ouvre une seconde session dans le même workspace. Mais le problème n'est pas
l'onglet, c'est le **worktree partagé** : deux sessions, un seul système de fichiers, donc
deux agents qui éditent les mêmes fichiers s'écrasent et se marchent dessus sur l'index git.
S'y ajoute une contrainte dure : le garde-fou passe **avant** le rafraîchissement, donc le
contourner ferait partir un `git reset --hard` sous les pieds de l'agent au travail.

Un run sauté est visible en orange dans l'historique et ne coûte rien. **Si de la
concurrence est vraiment voulue, la réponse architecturale existe déjà : la cible
« nouveau workspace à chaque run »**, qui donne un worktree isolé — au prix des ~2 Go par
exécution. Ne pas réintroduire d'option « lancer quand même » sans relire ce paragraphe.

### ⚠️ Les sessions ne meurent jamais — conséquence opérationnelle

Un agent lancé par `superset agents create` est une session **interactive** (les configs
d'agent n'ont pas `-p`) : elle ne se termine pas en fin de tâche, elle reste au prompt.
Mesuré sur ce poste — process `claude` encore vivants après **1 à 2 jours** dans quatre
worktrees distincts.

Conséquence directe : **une planification dont le worktree contient une session résiduelle
est sautée à chaque exécution, indéfiniment.** Ça n'était pas visible avant, parce que la
regex `pgrep` du script de référence était cassée (elle ratait les `claude` lancés avec des
arguments) : le garde-fou n'y tirait jamais, d'où l'accumulation. La version corrigée, elle,
tire vraiment.

**Décision : on ne compense pas côté outil, on ferme les sessions à la main** dans Superset
quand un run apparaît en orange. Trois pistes ont été examinées et écartées :

- **Durée de vie sur le garde-fou** (ignorer un agent de plus de N heures) : faisable en
  ~15 LOC via `ps -o etime`, mais ajoute un seuil arbitraire à comprendre lors d'un diagnostic.
- **Instruction « ferme ta session » dans le prompt** : le profil de permissions laisse la
  plupart des `Bash` sur `ask`, et un `ask` en session non surveillée **fige** l'agent —
  sans allow explicite, l'instruction le ferait pendre au lieu de le terminer. Et
  `superset terminals close` exige un `--terminal <id>` que l'agent ne connaît pas ; le
  registre est de toute façon peu fiable (`terminals list` a rendu `{"sessions": []}` alors
  que des process vivaient dans le worktree).
- **`claude -p`**, qui sortirait naturellement : exclu pour le cas Sentry — le MCP Sentry
  est un MCP HTTP distant en OAuth qu'un process non interactif ne peut pas authentifier
  (faux négatif « aucun outil Sentry disponible »).

## La CLI `superset`

`~/.superset/bin/superset` **n'est pas un exécutable Mach-O** : c'est un shim `#!/bin/sh`
qui `exec` le vrai binaire dans `Superset.app`. `posix_spawn` suit le shebang, donc
`Process.executableURL` sur le shim fonctionne — c'est le point d'entrée stable. Repli sur
le chemin interne à `Superset.app` s'il manque.

**Environnement nettoyé avant chaque appel** :

| Variable | Pourquoi |
|---|---|
| `CLAUDE_CODE_SSE_PORT` | court-circuite la découverte des locks IDE : l'agent spawné se brancherait sur un **port IDE mort** hérité |
| `POTOF_SESSION_ID` | clé de mapping des notifications : héritée, elle attribuerait les events du nouvel agent à une session Potof sans rapport |
| `CI`, `CLAUDECODE` | la CLI passe « auto-on `--json` under CI/agent envs » ⇒ parsing non déterministe. **`CI=1` seul suffit à faire sortir du JSON sans `--json`** (mesuré) : on nettoie **et** on passe `--json` partout |
| `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` | détourneraient le `fetch`/`reset` vers un autre dépôt |

Formes observées (CLI `1.18.3`, non contractuelles — décodage **tolérant** partout) :

- `agents list --local --json` rend `{ id, presetId, iconId, label, command, args, … }` —
  **ni `name`, ni `preset`**. `SupersetAgentConfig` mappe `label` → `name`,
  `presetId` → `preset`.
- **Un `id` d'agent n'est pas toujours un UUID** : l'entrée « Superset » a `id == "superset"`.
  Toute validation par regex UUID casserait.
- `status --json` rend `{ running, healthy, pid, port, endpoint, …, hostName }`, où
  `hostName` vaut **`null`** sur ce poste : ne rien construire dessus.
- `workspaces create` accepte `--local`, **`agents create` non** (il n'a que `--host`).
  `--prompt` est **obligatoire dès que `--agent` est posé**.

⚠️ **`superset start --daemon` est un piège de shell-out** : le daemon peut hériter de
stdout, donc `readDataToEndOfFile()` sur le thread appelant **ne revient jamais**, même
après la mort du fils. La lecture des pipes est déportée sur des files de fond — sans ça,
un job launchd resterait pendu indéfiniment.

## Notifications

`ScheduleNotifier.post(...)` — `UserNotifications`, depuis le runner, **uniquement** sur
`failed` ou `skipped`, et **uniquement** si `POTOF_SCHEDULE_TRIGGER == launchd`
(« Lancer maintenant » n'a rien à notifier, l'utilisateur regarde déjà l'écran). Appelée
**après** l'écriture de la ligne `end` : un canal de notification défaillant ne doit jamais
coûter la trace du run. Le sort de la bannière est lui-même consigné dans le log du run.

Pourquoi pas le canal interne de la cloche : `ChannelEvent.potofSessionId` est
non-optionnel (le runner n'a pas de session), et surtout `NotificationChannel.start()` fait
un `O_TRUNC` — une notif écrite app fermée serait effacée à l'ouverture suivante. Or
« app fermée » est le cas **nominal** d'un job de 10:00.

### ⚠️ Pourquoi pas `osascript`

C'était la première implémentation, calquée sur les scripts bash du poste. **Mesuré : elle
ne délivre rien.** Quatre runs launchd conclus en `skipped` ont appelé `/usr/bin/osascript`
avec un **code de sortie 0**, sans qu'aucune bannière n'apparaisse — et « Script Editor »
ne figure même pas dans les réglages de notification du poste. Un `display notification`
émis par le binaire `osascript` n'a pas d'identité d'app enregistrée, et macOS le jette en
silence. L'`exit 0` ne prouvait donc rien, ce qui rendait la panne indétectable.

L'identité correcte était disponible depuis le début : l'app **est** enregistrée
(`com.potof.potof-toolkit`) puisqu'elle pose déjà des bannières pour les sessions Claude.
Sous launchd, le runner s'exécute depuis `…/Potof Toolkit.app/Contents/MacOS/`, il porte
donc ce bundle. D'où `ScheduleNotifier`, isolé dans son fichier : `UserNotifications` n'est
ni AppKit ni SwiftUI, l'importer là ne met pas en péril la garantie structurelle de
`ScheduleRunner` (qui, lui, n'importe que `Foundation`).

⚠️ La garde `canPost` (= `pathExtension == "app"`, même garde que `canUseUN`) est
obligatoire : `UNUserNotificationCenter` **plante** sur un binaire nu, donc en `swift run`.

## Le mode headless et sa liste noire

`main.swift` reconnaît `--run-schedule` **avant** `NSApplication`, comme `--ide-selftest`.
`ScheduleRunner` n'importe que `Foundation` : avec ce seul import, `NSApp` devient une
**erreur de compilation**. Ce n'est pas une convention, c'est une garantie structurelle.

Le runner ne doit réveiller **aucun** de ces singletons (tous lazy, donc inertes tant qu'on
n'y touche pas) :

| Singleton | Ce qui casserait |
|---|---|
| `NotificationCenterCoordinator.shared` | son `start()` fait `open(…, O_TRUNC)` sur `notifications.jsonl` → **effacerait le canal de la GUI en cours**. Le plus vicieux. |
| `IDEHost.shared` | prend le lock `~/.claude/ide/<port>.lock` sur tout `$HOME` → deux IDE « valides » ⇒ plus aucune auto-connexion, des deux côtés |
| `IDELog.startSession()` | tronque `ide.log` de l'app vivante |
| `SessionStore` / `ScriptRunStore` / `*TerminalController` | tirent SwiftTerm, aucun intérêt |
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
manuelle.

## Débogage

```bash
potof-toolkit --run-schedule <uuid> --dry-run    # plan complet, AUCUN effet de bord
potof-toolkit --sched-selftest cli | plist | store | run
```

Le `--dry-run` imprime : santé du host service, workspace résolu (ou « serait créé »),
worktree, verdict de chaque garde-fou, argv exact de `superset agents create` (un argument
par ligne), prompt intégral, et le `.plist` qui serait installé.

⚠️ **Un garde-fou qui se déclenche est ANNOTÉ, il n'interrompt pas le plan**
(`⚠︎ un run réel s'arrêterait ici : …`), et le verdict final reflète ce qu'un run réel
aurait fait. Sans ça, l'outil de debug ne montrerait rien le jour où il y a justement
quelque chose à comprendre.

Un dry-run n'écrit **aucune** ligne d'historique et ne pose **aucun** verrou.

Le même dry-run est accessible depuis l'app : bouton **« Simuler le prochain run »** de la
top bar, résultat dans l'onglet **« Plan »**. Il simule le déclencheur `launchd` (et non
`manual`), parce que c'est le tir de 10:00 qu'on veut voir venir — la distinction compte,
le runner traite une planification désactivée différemment selon le déclencheur.

### ⚠️ Pourquoi il n'y a pas de « tester le déclencheur launchd »

Il y en a eu un. Il faisait `launchctl kickstart -k gui/<uid>/<label>` et se présentait
comme un diagnostic. **C'en était un run réel** : launchd exécute le `ProgramArguments` du
plist, c'est-à-dire `--run-schedule <uuid>` **sans** `--dry-run`. En trois clics il a créé
des workspaces, fait un `reset --hard` et lancé deux agents payants.

Et ce n'est pas rattrapable : le plist fige son argv, délibérément (aucun texte utilisateur
dans `~/Library/LaunchAgents`), donc **on ne peut pas demander à launchd une simulation**.
Le bouton a donc été supprimé, pas renommé — même raisonnement que `confirmEditInTerminal`
dans le pont IDE : une affordance qui ment sur son effet ne se corrige pas par un meilleur
libellé. `isLoaded(_:)` répond sans rien déclencher à la seule question que le kickstart
tranchait vraiment (« le job est-il chargé ? »), et le bandeau d'audit la pose tout seul.

**`ScheduleStore.runNow` est désormais le seul chemin de l'UI qui lance un run réel.**

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

## Hors périmètre v1

Jetons de substitution dans le prompt · vérification du livrable · `claude -p` en direct
comme seconde forme d'action · sélecteur d'agent au-delà de `--agent`/`--effort` · réveil
de la machine (`pmset`) · « dernier jour du mois » · intervalle non-diviseur de 24 ·
rattrapage automatique · suppression automatique des workspaces neufs.
