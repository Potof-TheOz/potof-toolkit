# Script Runner — scripts npm dans des terminaux possédés

Troisième outil du toolkit : découvre les `package.json` du poste, affiche leurs
scripts et les lance dans un **terminal embarqué** (SwiftTerm), sur le même modèle
de **process possédés par l'app** que les sessions Claude (`docs/SESSIONS.md`).
Différence clé avec les sessions : un run **survit à la fin de son process** — le
terminal reste affichable (sortie + scrollback) avec un badge de statut, jusqu'à
sa fermeture manuelle. Les runs ne sont **jamais persistés**.

## Vue d'ensemble

```
ScriptRunnerView / PackageDetailView (SwiftUI — projections jetables)
   │  clic ▶ sur un script → ScriptRunStore.launch(...)
   ▼
ScriptRunStore.shared (⭐ singleton : runs, statuts, sélection, machine d'arrêt)
   │  pilote
   ▼
ScriptTerminalController.shared ── [UUID: LocalProcessTerminalView] (une vue/PTY par run)
   │
LocalProcessTerminalView ── PTY ──▶ $SHELL -l -i ──▶ cd '<dir>' && <mgr> run '<script>'; exit
   ▲
   │  affichée (jamais recréée) par
Core/Terminal/TerminalHostView (vue partagée avec le Claude Launcher)
```

### Découverte des packages (`PackageStore`)

- **Scan** récursif de `$HOME` en tâche de fond (pattern `RepoStore` de Git Stuffs),
  avec une inversion : un `package.json` trouvé est enregistré **et on continue de
  descendre** (workspaces des monorepos). `node_modules`, sorties de build et
  dossiers cachés : élagués. Un `package.json` **directement à `$HOME`** est ignoré
  (il absorberait tous les projets en sous-entrées).
- **Cache** UserDefaults `scriptRunner.packageDirs` = chemins plats uniquement. Au
  chargement : filtrage des packages disparus + re-groupage. Auto-scan au tout 1er
  lancement seulement (`scriptRunner.didScanOnce`) ; ensuite bouton Rafraîchir.
- **Groupage monorepo** par remontée d'ancêtres : `Set` de tous les dossiers
  trouvés ; pour chaque dossier, l'ancêtre le **plus haut** présent dans le Set
  (jusqu'à `$HOME` exclu) est sa racine ; aucun → il est lui-même racine. Jamais de
  tri lexicographique (`/a/b-x` s'intercale entre `/a/b` et `/a/b/c`).
- **Manifest relu à chaud** (`PackageManifest.load`) à chaque affichage du détail et
  au retour de l'app au premier plan — jamais mis en cache (les scripts changent
  souvent).
- **Manager détecté par lockfile à la racine du PROJET** (pas du workspace — c'est
  la racine qui porte le lockfile) : `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn,
  `bun.lockb`/`bun.lock` → bun, sinon npm.

## Modèle d'exécution

1. `ScriptRunStore.launch` : **un run actif max par (package, script)** — s'il en
   existe déjà un (`.running`/`.stopping`), simple focus, pas de second lancement.
2. `ScriptTerminalController.start` spawne **`$SHELL -l -i`** dans le dossier du
   package (login + interactif → rc sourcés → PATH complet : nvm, corepack…), puis
   écrit après ~0,35 s : `cd '<dir>' && <mgr> run '<script>'; exit⏎` (apostrophes
   échappées `'` → `'\''`).
   - **`; exit` et PAS `&&`** → le shell meurt aussi quand le script échoue.
   - **`exit` sans argument propage `$?`** → la fin du script tue le shell, et
     `processTerminated` devient LE signal de fin, porteur du code du script.
3. `processTerminated` livre le statut waitpid **BRUT** (exit 1 = `256`, SIGKILL
   = `9`) → décodage via `ScriptRun.decodeWaitStatus` : exité si `(raw & 0x7f) == 0`
   → code `(raw >> 8) & 0xff` ; sinon tué par le signal `raw & 0x7f`.
4. Statuts : `.running` / `.stopping` (arrêt demandé) / `.exited(code:)` /
   `.killed(signal:)`. La vue terminal est **conservée après la mort du process**
   (scrollback lisible, badge posé) ; seule la fermeture manuelle la libère.
   - Fermer un run **vivant** : `hardKill` immédiat, mais libération de la vue +
     retrait de la liste **différés à la mort réelle** du process (`handleExit`) —
     jamais de vue libérée process vivant.
   - Fermer un run **terminé** : libération + retrait immédiats.

## Séquence d'arrêt (bouton Stop → `ScriptRunStore.stop`)

Arrêt **gradué**, poll toutes les 0,5 s sur la main queue ; chaque étape est gardée
par `isRunning` (le `send` de SwiftTerm est un no-op silencieux sur process mort).

- **(a) t = 0 — Ctrl-C.** `send("\u{03}")`, statut → `.stopping`. La line
  discipline du PTY (ISIG) traduit 0x03 en **SIGINT délivré au groupe de premier
  plan entier** — le script ET ses enfants (vite, esbuild…) — exactement comme un
  Ctrl-C tapé au clavier. C'est la voie « propre » (le cleanup du script s'exécute).
- **(b) ticks à 0,5 s — `exit` quand le shell est au prompt.** zsh interactif
  **jette** le `; exit` restant de la ligne après un Ctrl-C : le shell survit au
  script et il faut le faire sortir explicitement (`send("exit\r")`, UNE fois).
  Le garde `tcgetpgrp(childfd) == shellPid` (= le shell est **revenu au prompt**)
  est indispensable : tant que le groupe de premier plan est encore celui du script
  (shutdown gracieux en cours), écrire `exit` irait dans **son** stdin, pas dans
  celui du shell.
- **(c) t ≈ 3 s — SIGKILL.** SIGINT ignoré ou shutdown interminable → `hardKill` :
  lire `fd = process.childfd` **avant tout** (il passe à -1 à l'EOF/libération),
  `kill(-tcgetpgrp(fd), SIGKILL)` — le **job entier**, car sous job control le
  script vit dans un groupe distinct du shell — puis `kill(shellPid, SIGKILL)`.
  **Surtout PAS `terminate()` de SwiftTerm** pour cette escalade : il annule le
  DispatchSourceProcess → `processTerminated` n'arriverait jamais et le badge
  resterait figé. Le monitor, resté armé, livre raw = 9 → `.killed(signal: 9)`.

**Normalisation 130** : après notre Ctrl-C, le shell propage le plus souvent
`exit 130` (128 + SIGINT) — un statut *exited* côté waitpid alors que,
sémantiquement, l'utilisateur a arrêté le script. `handleExit` le requalifie en
`.killed(signal: SIGINT)` (badge « arrêté », gris) **uniquement si le run était
`.stopping`** (Stop piloté) ; hors Stop, le statut décodé est gardé tel quel.

## Garde-fous

- **Quit de l'app** : `applicationShouldTerminate` affiche une **alerte combinée**
  (« X sessions Claude et Y scripts actifs ») ; à la confirmation,
  `applicationWillTerminate` appelle `ScriptTerminalController.terminateAll()` =
  `hardKill` de tous les process vivants + libération des vues. Le SIGKILL
  explicite des **groupes** est nécessaire : fermer le fd maître du PTY ne SIGHUPe
  pas un dev server qui l'ignore (ports orphelins sinon).
- **Survie au changement d'outil** : `RootView` détruit la vue de l'outil (et ses
  `@StateObject`) au switch → runs, terminaux, statuts et sélection vivent dans
  `ScriptRunStore.shared` + `ScriptTerminalController.shared` (singletons
  app-level). Même invariant que `SessionStore.shared` côté Claude Launcher :
  **changer d'outil ne perd jamais un terminal**.

## Limites connues

- **Ordre des scripts** : alphabétique, pas celui du `package.json` (Foundation ne
  préserve pas l'ordre des clés JSON).
- **`$SHELL` = fish non géré** : l'échappement `'` → `'\''` et la ligne
  `cd … && … ; exit` visent zsh/bash (limitation partagée avec le Claude Launcher).
- **Délai fixe ~0,35 s** avant l'écriture de la commande (le temps que le shell
  s'initialise) : empirique ; rc lourds → l'augmenter dans `ScriptTerminalController`.

## Fichiers

| Fichier | Rôle |
|---|---|
| `Tools/ScriptRunner/PackageProject.swift` | Modèles `ScriptPackage` (id = chemin) + `PackageProject { root, subpackages }` |
| `Tools/ScriptRunner/PackageStore.swift` | Scan `$HOME` (fond) + groupage + cache `scriptRunner.packageDirs` |
| `Tools/ScriptRunner/PackageManifest.swift` | Relecture à chaud de `package.json` (name, scripts triés) |
| `Tools/ScriptRunner/PackageManager.swift` | npm/pnpm/yarn/bun : détection lockfile racine + `runCommand` échappé |
| `Tools/ScriptRunner/ScriptRun.swift` | Modèle d'un run + `Status` + `decodeWaitStatus(raw)` |
| `Tools/ScriptRunner/ScriptTerminalController.swift` | Possède les vues/PTY (1/run), spawn + primitives d'arrêt |
| `Tools/ScriptRunner/ScriptRunStore.swift` | ⭐ Singleton : launch/stop/close/focus + machine à états de l'arrêt |
| `Tools/ScriptRunner/ScriptRunnerView.swift` | UI : sidebar (exécutions + projets) \| centre (run ou détail) |
| `Tools/ScriptRunner/PackageDetailView.swift` | Détail package : scripts + badge manager + ▶ |
| `Core/Terminal/TerminalHostView.swift` | Place la vue terminal du run affiché (partagée avec le Launcher) |
