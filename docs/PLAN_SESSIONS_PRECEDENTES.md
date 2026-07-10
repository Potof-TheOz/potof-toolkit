# Plan — Section « Sessions précédentes » (Claude Launcher)

> Statut : **✅ IMPLÉMENTÉ** le 2026-07-10 (UI + fonctionnement validés).
> L'accès final est un **bouton + popover** dans la sidebar (et non une section
> permanente — choix « moins gênant »). Doc de référence : `docs/SESSIONS.md`
> (section « Sessions précédentes »). Ce fichier reste comme trace de l'analyse.

## 0. Objectif

Ajouter, dans la sidebar du Claude Launcher, une section **« Précédentes »**
listant les sessions Claude Code passées, au même endroit et dans le même style
que « Sessions actives ». Un clic **reprend** la session (`claude --resume`).
Périmètre restreint aux **dossiers visibles dans la sidebar**.

## 1. Ce que sont les « sessions précédentes »

Claude Code écrit l'historique de chaque conversation dans :

```
~/.claude/projects/<dossier-encodé>/<sessionId>.jsonl
```

- `<dossier-encodé>` = chemin absolu du `cwd`, avec `/`, `.` (et `_`) remplacés
  par `-`. Vérifié : `/Users/julien.valery/WebstormProjects/potof-toolkit`
  → `-Users-julien-valery-WebstormProjects-potof-toolkit`.
- Le **nom du fichier `.jsonl` est le `sessionId`** (UUID) — directement
  réutilisable pour `claude --resume <id>`.

Métadonnées disponibles dans les lignes JSONL :

| Donnée        | Source                                              | Usage UI                    |
|---------------|-----------------------------------------------------|-----------------------------|
| **Titre**     | ligne `ai-title` → `aiTitle`                        | libellé principal           |
| Dernier prompt| ligne `last-prompt` → `lastPrompt`                  | fallback / sous-titre       |
| Dossier réel  | champ `cwd` (lignes `user`/`assistant`)             | **désambiguïsation matching**|
| Branche git   | `gitBranch`                                         | sous-titre optionnel        |
| Récence       | `timestamp` des lignes / **mtime du fichier**       | tri anti-chronologique      |

## 2. Faisabilité — risques & parades

**a. Encodage lossy → ne pas s'y fier seul.** `julien.valery` et `julien/valery`
encodent tous deux `julien-valery` ; le décodage inverse n'est pas fiable.
**Parade** : encodage *forward* (chemin affiché → dir candidat, déterministe) pour
localiser vite le dossier projet, puis **confirmation via le `cwd`** lu dans le
fichier. Évite un scan complet de `~/.claude/projects/` et couvre la collision.

**b. Perf — fichiers jusqu'à ~2,6 Mo, `ai-title` dispersé.** `ai-title` est
**réécrit** au fil de la conversation (1re occurrence observée en ligne 9/41/51/60
selon les fichiers) : le titre courant est la **dernière** occurrence, pas lisible
en tête. **Parades** : (1) parsing sur **queue de fond**, jamais sur le thread
principal ; (2) **cache par `(path, mtime)`** — re-parse uniquement si le fichier a
changé ; (3) option : lecture du **tail** (~64 Ko en fin de fichier) où
`ai-title`/`last-prompt` récents se trouvent presque toujours, avec repli sur
lecture complète. La récence de tri vient du `mtime` (gratuit, sans lecture).

**c. Reprise — confirmée.** `claude -r, --resume [value]` reprend par session ID.
Option `--fork-session` disponible si besoin d'éviter d'écraser une session déjà
vivante sur le même ID (non retenue par défaut).

**d. Contrat non-officiel.** `~/.claude/projects/…` et le format JSONL ne sont pas
garantis par Claude. À traiter comme le pont IDE : **tolérant** (titre absent →
repli `lastPrompt` → nom du dossier ; dossier absent → section vide, aucun crash).

**e. Dev vs bundle : non concerné.** On lit `~/.claude` (chemin utilisateur
absolu), pas `Bundle.module` — aucun impact du garde-fou `canUseUN`/icône.

## 3. Interprétation de « uniquement si le dossier root est présent dans l'interface »

N'afficher une session précédente que si son `cwd` correspond à un **dossier
actuellement visible dans la sidebar** (sous-dossiers du root scanné + favoris
affichés). Réutilise `subfolders`/`favoriteFolders` déjà en mémoire.

## 4. Décisions produit (verrouillées)

- **Clic = reprise** via `claude --resume <id>` : lance une **nouvelle session
  possédée** (nouveau `POTOF_SESSION_ID`), pas de fork.
- **Périmètre = dossiers visibles dans la sidebar** (sous-dossiers du root +
  favoris affichés), confirmé par le `cwd`.

## 5. Plan d'implémentation

### Fichiers à créer (`Sources/potof-toolkit/Tools/ClaudeLauncher/`)

1. **`PreviousSession.swift`** — modèle :
   `{ id: sessionId (UUID/String), folderURL, title, subtitle, lastUsed: Date, gitBranch }`.

2. **`PreviousSessionsStore.swift`** (`ObservableObject`) — cœur de la feature :
   - `refresh(for folders: [FolderItem])` : pour chaque dossier visible → encode
     forward → probe `~/.claude/projects/<enc>/` → liste les `.jsonl` → parse en
     **queue de fond** → confirme `cwd` → publie `@Published var sessions` trié
     par `lastUsed` desc.
   - Cache `[path: (mtime, PreviousSession)]` : re-parse uniquement le changé.
   - **Exclut** les `sessionId` déjà actifs (pas de doublon avec « Sessions
     actives » ; comparer aux sessions du `SessionStore`).
   - Parsing tolérant : dernier `ai-title` → repli `lastPrompt` → nom du dossier.

### Fichiers à modifier

3. **`ClaudeLauncherView.swift`** :
   - Nouvelle `previousSessionsSection` (miroir de `sessionsSection`, en-tête
     `sectionHeader(title: "Précédentes", systemImage: "clock.arrow.circlepath",
     tint: .secondary, count:)`), rendue **sous** « Sessions actives ».
   - Câblage `refresh` sur `.onAppear`, `NSApplication.didBecomeActiveNotification`,
     et changements de `subfolders` + `favorites` + `scope` (mêmes déclencheurs
     que `scan()` / `loadFavorites()`).
   - Clic sur une ligne → `sessions.launch(folder:resume:)`.
   - Ligne dédiée (type `PreviousSessionRow`) : titre + sous-titre + récence.

4. **`SessionStore.swift`** : `launch(folder:resume: String? = nil)`
   (rétro-compatible ; `resume == nil` = comportement actuel).

5. **`TerminalController.swift`** : propager `resume` jusqu'à
   `launchCommand(folder:resume:)` →
   `cd '<dossier>' && claude --resume <id>` (échappement apostrophe `'` → `'\''`
   conservé). Injection `POTOF_SESSION_ID` inchangée.

### Documentation

6. Note du contrat non-officiel `~/.claude/projects/…` dans `CLAUDE.md`
   (invariants) et/ou `docs/SESSIONS.md`.

## 6. Étapes

1. Modèle + parsing (dernier `ai-title`, repli `lastPrompt`, `cwd`, `mtime`) avec
   mini-spike de perf sur les gros `.jsonl`.
2. Store + cache `(path, mtime)` + matching forward-encode / confirmation `cwd`.
3. Section UI + tri anti-chronologique + exclusion des sessions déjà actives.
4. Reprise (`launch(resume:)` → `--resume`).
5. Rafraîchissement sur les mêmes événements que `scan()` / `loadFavorites()`.
6. Vérification via `./Scripts/build-app.sh` + `open -a` (pas `swift run` — il
   s'auto-quitte en tâche de fond).

## 7. Points de vigilance (invariants à ne pas casser)

- Parsing JSONL **hors thread principal** ; publication des `@Published` sur `main`.
- Aucune écriture disque sur `~/.claude/` (lecture seule).
- Aucune nouvelle dépendance externe (SwiftTerm reste la seule).
- Reprise = nouvelle session possédée : fermer la tue (contrat existant).
- Style et découplage cohérents avec l'existant (pas de MVVM lourd).
