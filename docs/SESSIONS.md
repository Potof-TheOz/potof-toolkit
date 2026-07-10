# Sessions Claude embarquées

Cœur du **Claude Launcher** : l'app **héberge elle-même** les sessions `claude`
dans un **terminal embarqué** (SwiftTerm), au lieu de piloter iTerm2 depuis
l'extérieur. Chaque session est un process `claude` tournant dans un **PTY dont
l'app est le parent**.

> Remplace l'ancien modèle iTerm2 (AppleScript + sessions « dérivées en direct »).
> Conséquence directe : **fermer une session = tuer son process** (l'app le possède).

## Vue d'ensemble

```
ClaudeLauncherView (SwiftUI)
   │  clic sur un dossier → SessionStore.launch(folder:)
   ▼
SessionStore (ObservableObject, source de vérité UI)
   │  possède
   ▼
TerminalController (NSObject, délégué SwiftTerm)
   │  possède [UUID: LocalProcessTerminalView]  (une vue/PTY par session)
   ▼
LocalProcessTerminalView (SwiftTerm)  ── PTY ──▶  $SHELL -l  ──▶  claude
   ▲
   │  affichée (jamais recréée) par
TerminalHostView (NSViewRepresentable)
```

## Cycle de vie d'une session

### Lancer — `SessionStore.launch(folder:resume:)`
1. Crée une `Session { id: UUID, folderURL, title, status: .running }` et l'ajoute
   à `sessions` (publié → la sidebar s'actualise), puis l'active (`activeID`).
2. `TerminalController.start(id:folder:)` crée un `LocalProcessTerminalView` et
   lance **`$SHELL -l -i`** (login + interactif) via `startProcess`, avec :
   - `currentDirectory` = le dossier,
   - `environment` = les défauts SwiftTerm (`TERM=xterm-256color`,
     `COLORTERM=truecolor`, `LANG`…) **+ `POTOF_SESSION_ID=<uuid>`** (ancrage notif,
     cf. `NOTIFICATIONS.md`).
3. Un shell **login + interactif** source les rc de l'utilisateur (`.zprofile`,
   `.zshrc`, Homebrew, nvm…) → **PATH complet**, donc `claude` est résolu comme il
   l'était dans iTerm2. Le `-i` explicite couvre les shells (ex. bash) qui ne
   sourcent `.*rc` qu'en mode interactif.
4. Après un court délai (~0,35 s, le temps que le shell s'initialise), on **écrit**
   `cd '<dossier>' && claude⏎` dans le terminal — équivalent du `write text` d'iTerm2.
   Si `resume` (id de conversation Claude) est fourni — reprise d'une **session
   précédente** —, la commande devient `cd '<dossier>' && claude --resume '<id>'⏎`
   (cf. section « Sessions précédentes »).

### Afficher — `TerminalHostView`
- N'affiche **jamais** deux fois la même vue et **ne recrée pas** les vues : elle
  demande au `TerminalController` la vue de la session active et la place dans un
  conteneur (contraintes plein cadre). Changer de session = échanger la sous-vue,
  **sans perdre scrollback ni process**.
- Donne le focus clavier au terminal affiché (`makeFirstResponder`).

### Fermer — `SessionStore.close(id:)`
- `TerminalController.terminate(id:)` **coupe d'abord le delegate** (pour ne pas
  déclencher le chemin « exit spontané »), appelle `terminate()` (tue le process du
  PTY) puis libère la vue. La session est retirée de `sessions` ; si c'était
  l'active, on bascule sur la dernière restante.

### Sortie spontanée (Claude quitte tout seul)
- Le delegate `processTerminated` remonte `onProcessExit(id, code)` **sur le thread
  principal** → `SessionStore.handleExit` libère la vue et retire la session.
  Fidèle à l'esprit « pas de session fantôme » : la liste reflète les process vivants.

## Invariants (à ne pas casser)

- **Les `LocalProcessTerminalView` sont possédées par `TerminalController`**, une par
  session, **conservées vivantes** tant que la session existe. `TerminalHostView` ne
  fait que les *placer*. Les recréer perdrait le process et le scrollback.
- **Toutes les mutations d'état** (`views`, `idByView`, `@Published sessions/activeID`)
  se font **sur le thread principal**. Les callbacks du delegate SwiftTerm y sont
  remarshalés (`DispatchQueue.main.async`) pour éviter les data races.
- **Login shell interactif (`$SHELL -l -i`) obligatoire** pour hériter du PATH
  utilisateur. Ne pas lancer `claude` en direct (le PATH par défaut de SwiftTerm
  **exclut** `PATH`).
- **Quitter l'app tue les process** des sessions (l'app en est le parent).
  `AppDelegate.applicationShouldTerminate` **confirme** s'il reste des sessions
  actives (⌘Q ou fermeture de fenêtre). Ne pas retirer ce garde-fou.
- **`POTOF_SESSION_ID`** est injecté dans l'environnement de chaque session : c'est la
  clé qui relie un event Claude à sa session pour les notifications (`NOTIFICATIONS.md`).
- **Report souris : clic/survol coupés, molette forwardée** (`EmbeddedTerminalView` +
  `allowMouseReporting = false`). Un survol/clic de la souris **ne doit jamais** être
  transmis à la TUI de Claude — sinon passer la souris sur un bouton « Yes »/« No » (ex.
  quand la fenêtre passe au premier plan via une notif) **valide le prompt de permission à
  l'insu de l'utilisateur**. `allowMouseReporting = false` gère clic/drag ;
  `EmbeddedTerminalView.send(source:data:)` filtre en plus les reports SGR **de bouton
  < 64** (survol/motion inclus, que SwiftTerm ne garde pas derrière le drapeau). La
  sélection de texte native et le clavier restent intacts.
- **Scroll = molette forwardée à la TUI.** SwiftTerm-mac ne forwarde **jamais** la molette :
  son `scrollWheel` ne fait que du scrollback **local** (buffer normal), inutile quand
  Claude possède l'écran. `EmbeddedTerminalView` intercepte donc la molette via un
  **moniteur d'événements local** (`NSEvent.addLocalMonitorForEvents`, car `scrollWheel` est
  `public` non `open` hors de notre module → non surchargeable) et la traduit en reports
  « bouton molette » (64 = haut, 65 = bas) quand le suivi souris est actif — le filtre
  `send` laisse passer les boutons **≥ 64**. Ces reports **ne peuvent pas** sélectionner un
  prompt Yes/No. Sans suivi souris (shell nu) ou curseur hors du terminal, on retombe sur le
  comportement natif (scrollback local). Le moniteur est branché sur `viewDidMoveToWindow`,
  donc actif **uniquement sur la session affichée**. Ne pas réactiver le report souris pour
  clic/survol.
- **App Sandbox désactivée** : requise pour qu'un sous-process lancé dans un PTY ait
  accès au disque et aux commandes (cf. remarque SwiftTerm). Ne pas l'activer.

## Sessions précédentes (reprise)

La sidebar propose un bouton **« Voir les sessions précédentes »** (visible s'il y
en a) qui ouvre une **popover** listant les conversations Claude passées des
**dossiers visibles** (sous-dossiers du root + favoris). Un clic **reprend** la
session : `SessionStore.launch(folder:resume:)` → une nouvelle session possédée qui
exécute `claude --resume '<id>'` (nouveau `POTOF_SESSION_ID`, la reprise ne
réutilise pas l'ancien).

Source des données : les fichiers `.jsonl` que Claude Code range dans
`~/.claude/projects/<dossier-encodé>/`. **Contrat non-officiel** (comme le pont IDE),
**vérifié empiriquement** — donc traité en **lecture seule et tolérant** (un titre
absent ou un dossier introuvable ne casse rien).

- **Encodage du dossier** : `<dossier-encodé>` = le chemin absolu du `cwd` avec
  `/`, `.` et `_` remplacés par `-`. `PreviousSessionsStore` fait cet **encodage
  forward** (rapide) pour localiser le bucket d'un dossier visible.
- **`cwd` = clé d'appartenance, pas le nom du dossier.** Le nom encodé peut
  **mentir** (ex. le bucket `…-claude-launcher` contient en réalité des sessions
  dont le `cwd` est `…/potof-toolkit`, séquelle d'un renommage). On lit donc le
  `cwd` **dans** chaque fichier et on ne garde la session que si son `cwd` résolu
  **matche** le dossier visible ciblé (rejette les buckets « mixtes »).
- **Titre** : dernier `aiTitle` du JSONL (réécrit au fil de la session, donc pas
  en tête → parsing complet en une passe), à défaut `lastPrompt` tronqué, à défaut
  le nom du dossier. **Récence** = `mtime` du fichier (gratuit).
- **Perf** : parsing sur une **queue de fond**, cache par `(chemin, mtime)`
  (re-parse seulement si le fichier change), refresh sur événements discrets
  (apparition, retour au premier plan, changement de dossiers/favoris).

Limite connue : une session stockée dans un **bucket renommé** (nom encodé ≠ cwd)
n'apparaît que si l'on scanne ce bucket — l'encodage forward part du dossier
visible, donc un vieux bucket orphelin peut être manqué. Acceptable (historique
ancien) ; un scan inverse de tout `~/.claude/projects` serait plus complet mais
bien plus coûteux.

## Fichiers

| Fichier | Rôle |
|---|---|
| `Tools/ClaudeLauncher/Session.swift` | Modèle `{ id, folderURL, title, status }` |
| `Tools/ClaudeLauncher/SessionStore.swift` | Source de vérité UI : `launch` / `close` / `focus` |
| `Tools/ClaudeLauncher/PreviousSession.swift` | Modèle d'une session passée `{ id, folderURL, title, lastUsed, gitBranch }` |
| `Tools/ClaudeLauncher/PreviousSessionsStore.swift` | Lit/parse `~/.claude/projects` (fond + cache `mtime`), matche par `cwd` |
| `Tools/ClaudeLauncher/TerminalController.swift` | Possède les vues/PTY, spawn/kill, délégué SwiftTerm |
| `Tools/ClaudeLauncher/TerminalHostView.swift` | `NSViewRepresentable` : affiche la session active |
| `Tools/ClaudeLauncher/ClaudeLauncherView.swift` | UI : sidebar (sessions + dossiers/favoris) + terminal central |

## Limites connues

- Le PATH dépend du sourcing des rc par `$SHELL -l -i`. Une config qui ne pose le
  PATH ni en login ni en interactif (rare) empêcherait de résoudre `claude`.
- Le délai fixe (~0,35 s) avant l'auto-`cd && claude` est empirique. Si la commande
  s'écrit trop tôt sur des machines lentes (rc lourds : nvm, conda…), l'augmenter
  dans `TerminalController`.
- Le rendu dépend des capacités de SwiftTerm (alt-screen, couleurs vraies, resize) —
  validé avec la TUI plein écran de Claude.
