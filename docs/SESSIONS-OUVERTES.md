# Sessions iTerm2 ouvertes

Fonctionnalité du **Claude Launcher** : repérer les onglets iTerm2 où une session
Claude tourne déjà, les afficher en tête de liste, et y **revenir en un clic** au lieu
d'en rouvrir une.

## Principe : dérivation en direct (aucun stockage)

À chaque affichage/rafraîchissement, l'outil **interroge iTerm2** (AppleScript) pour
lister ses sessions et leur répertoire courant, puis rapproche ce répertoire des
dossiers listés. Rien n'est persisté :

- pas de capture au lancement, pas d'`id` mémorisé, pas de clé `UserDefaults` ;
- la liste **reflète toujours l'état réel** d'iTerm2 → aucune entrée « fantôme » : un
  onglet fermé disparaît de lui-même au rafraîchissement suivant.

## Comment ça marche

### 1. Lister les sessions — `ITermLauncher.listSessions()`
- **Ne fait rien si iTerm2 n'est pas déjà lancé** (`NSWorkspace.runningApplications`
  filtré sur le bundle id `com.googlecode.iterm2`) → renvoie `[]`. Le script **n'utilise
  pas `activate`** : ouvrir Potof ne doit jamais démarrer iTerm2.
- AppleScript parcourant `windows → tabs → sessions` et, pour chaque session, récupérant
  `id`, `name` et `variable named "path"` (le répertoire courant). Ce `path` est fiable
  même sans *Shell Integration* : iTerm2 le déduit du process au premier plan — donc du
  `claude`/`node` lancé dans le dossier.
- Sortie sérialisée avec des **séparateurs de contrôle** (`character id 31`/`30`,
  improbables dans un chemin ou un titre) puis parsée en `[ITermSession]`. Les sessions
  sans `path` sont ignorées.

### 2. Rapprocher des dossiers listés
- Correspondance **exacte** : le `path` de la session doit être **égal** au chemin d'un
  dossier listé (favoris + sous-dossiers scannés), après normalisation (liens
  symboliques résolus, slash final retiré). Cohérent avec le lancement
  `cd '<dossier>' && claude` (le cwd du process = le dossier).
- Une session dont le dossier n'est pas listé (hors racine et non favori) n'est pas
  affichée.

### 3. Revenir sur l'onglet — `ITermLauncher.focus(sessionId:)`
- AppleScript qui `activate` iTerm2, retrouve la session par son `id` et fait
  `select` fenêtre + onglet + session. Renvoie `false` si l'`id` n'existe plus.

## UI (`ClaudeLauncherView`)

- État éphémère `@State openSessions: [ITermSession]` (jamais persisté), alimenté par
  `refreshSessions()` — exécuté **hors du thread principal** (aller-retour Apple Event)
  sur une **file série** dédiée (évite deux exécutions AppleScript concurrentes).
- Rafraîchi aux mêmes moments que le scan des dossiers : `.onAppear`,
  `NSApplication.didBecomeActiveNotification` (retour au premier plan) et le bouton
  **Rafraîchir** (⌘R). Combinés dans `refreshAll()`.
- **Section « Sessions ouvertes »** en tête du navigateur (au-dessus de Favoris / Tous
  les dossiers), une carte par session (icône `terminal.fill`, nom du dossier + titre de
  la session), clic ⇒ `focus(sessionId:)`.
- **Badge** (pastille verte) sur les cartes de dossier ayant au moins une session
  ouverte (`openSessionPaths`).

### Comportement des clics (volontaire)
- Carte de la **section du haut** = rejoindre l'onglet existant (`focus`).
- Carte de **dossier** (bas) = lancer une **nouvelle** session (`launch`), comme avant ;
  le badge est purement informatif.

## Fichiers

| Fichier | Rôle |
|---|---|
| `Tools/ClaudeLauncher/ITermSession.swift` | Modèle `{ id, path, name }` (dérivé, non persisté) |
| `Tools/ClaudeLauncher/ITermLauncher.swift` | `launch(at:)`, `listSessions()`, `focus(sessionId:)` — tout l'AppleScript iTerm |
| `Tools/ClaudeLauncher/ClaudeLauncherView.swift` | Section, badges, `refreshSessions()`/`refreshAll()`, correspondance |

## Limites

- **Correspondance exacte** uniquement : une session dont le cwd est un *sous-dossier*
  d'un projet listé n'est pas rattachée.
- Dépend d'iTerm2 (bundle id `com.googlecode.iterm2`) et de l'autorisation Automation
  (voir `LIFECYCLE.md` §4). Un autre terminal n'est pas géré.
- Le `path` provient de la détection iTerm2 ; dans de rares configurations sans détection
  de répertoire, une session pourrait ne pas être rapprochée.
