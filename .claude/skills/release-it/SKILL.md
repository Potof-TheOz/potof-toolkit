---
name: release-it
description: >-
  Livrer Potof Toolkit, en deux temps selon la branche courante. Hors `main`
  (branche de feature / worktree) : review du diff, commit(s) conventionnels et
  push de la branche — SANS bump de version, tag ni déploiement. Sur `main` :
  release complète (review, commit, bump, chore(release), tag, push, déploiement
  local qui remplace « Potof Toolkit.app » dans ~/Applications). À utiliser quand
  l'utilisateur veut « release », « livrer », « publier », « déployer l'app », ou
  faire la partie « review + commit + push » d'une branche.
---

# release-it — livrer Potof Toolkit

Le comportement dépend de la **branche courante** — la déterminer **en premier** :
`git rev-parse --abbrev-ref HEAD`.

- **Hors `main`** (branche de feature, worktree) → **review → commit(s) → push** de la
  branche. **PAS** de bump de version, **PAS** de tag, **PAS** de déploiement : ils se
  feront plus tard, sur `main`. ⚠️ Ne jamais builder/déployer dans `~/Applications`
  hors `main` (cf. CLAUDE.md, « pas de déploiement sauvage »).
- **Sur `main`** → **release complète** : review → commit(s) → bump → `chore(release)` →
  tag → push (`main` + tag) → déploiement local.

## Contexte du repo (à connaître avant d'agir)

- **Version = source unique dans `Scripts/build-app.sh`** (pas de fichier `VERSION`,
  pas dans `Package.swift`). Deux clés à bumper ensemble dans le heredoc Info.plist :
  - `CFBundleShortVersionString` → version marketing `X.Y.Z` (ex. `1.2.1`).
  - `CFBundleVersion` → **entier monotone** incrémenté de +1 à chaque release (ex. `6` → `7`).
- **Convention** : commits conventionnels (`feat:`, `fix:`, `perf:`, `refactor:`,
  `chore:`…). Sur `main`, la release elle-même est un commit **séparé**
  `chore(release): X.Y.Z` qui ne contient QUE le bump de `build-app.sh`.
- **Tag** : `vX.Y.Z` (préfixe `v`) — **sur `main` uniquement**.
- **Branches** : le travail se fait sur des **branches de feature / worktrees** ; le
  bump, le tag et le déploiement se font sur **`main`**. Remote : `origin`.
- **Deploy local** (`main` uniquement) : `./Scripts/build-app.sh` compile en release,
  `rm -rf` l'ancien bundle et réinstalle `~/Applications/Potof Toolkit.app`
  (Launch Services réenregistré).
- Chaque commit git se termine par le trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Étapes communes (les deux modes)

### 1. État des lieux
- `git status` + `git diff` (et `git diff --staged`) pour voir tout le travail en cours.
- `git fetch origin` puis vérifier qu'on **n'est pas en retard / divergent** sur l'amont
  de la branche courante (`git status -sb`). Si en retard/divergent → **stop**, prévenir
  l'utilisateur (ne pas rebaser/merger de force).
- `git tag --sort=-v:refname | head -1` → dernière version publiée (utile surtout en mode `main`).
- S'il n'y a **rien à livrer** (working tree propre ET aucun commit local en avance sur
  l'amont) → le dire et s'arrêter.

### 2. Review (bloquant)
- Lancer le skill **`code-review`** sur le diff courant (working tree + commits locaux
  non poussés).
- Traiter les findings **CONFIRMED de correction** comme bloquants : les présenter,
  proposer un correctif, **ne pas continuer** tant qu'ils ne sont pas résolus ou que
  l'utilisateur ne demande pas explicitement de passer outre.
- Findings de style/simplification : les signaler, non bloquants.

### 3. Commit(s) du travail
- Regrouper le travail en cours en commit(s) conventionnels **au bon grain**
  (un sujet = un commit ; ex. `feat(git-stuffs): …`). S'inspirer du style des messages
  récents (`git log --oneline -15`).
- Ne PAS inclure de bump de `build-app.sh` ici : c'est un commit à part, **mode `main`**.

---

## Mode HORS `main` (branche de feature / worktree)

### 4a. Point de contrôle (léger)
Récap : liste des commits qui seront créés (messages) + « je vais pousser la branche
`<branche>` sur `origin` ». Demander le feu vert (sauf si l'utilisateur a déjà exprimé
une intention claire de « va au bout »).

### 5a. Push de la branche
- `git push origin <branche courante>` (`git push -u origin <branche>` si pas d'upstream).

### 6a. Compte rendu
- Commits créés, branche poussée (+ lien PR si pertinent).
- **Rappeler** que le bump de version, le tag `vX.Y.Z` et le déploiement local se feront
  **sur `main`** (via ce même skill), une fois le travail intégré.

**FIN** — pas de bump, pas de tag, pas de `build-app.sh` (déploiement).

---

## Mode SUR `main` (release complète)

### 4b. Décider du bump de version
Depuis la dernière release, à partir des commits/diff à inclure :
- un `feat:` (ou plusieurs) sans breaking change → **minor** (`X.Y+1.0`) ;
- uniquement `fix:` / `perf:` / `refactor:` / `chore:`… → **patch** (`X.Y.Z+1`) ;
- un `BREAKING CHANGE` ou un `!` (ex. `feat!:`) → **major** (`X+1.0.0`).
`CFBundleVersion` = ancien + 1 dans tous les cas.
Annoncer le bump retenu (et le raisonnement) au point de contrôle.

### 5b. Point de contrôle (confirmation unique)
Avant toute action irréversible (push, tag, remplacement de l'app), présenter un récap :
- version cible `X.Y.Z` (+ build number) et pourquoi ;
- liste des commits qui seront créés (messages) ;
- « je vais : commit → tag `vX.Y.Z` → push `main` + tag → remplacer l'app locale ».

Demander le feu vert. Si l'utilisateur a invoqué le skill avec une intention claire de
« va jusqu'au bout », enchaîner sans re-questionner à chaque sous-étape.

### 6b. Bump + commit de release
- Éditer `Scripts/build-app.sh` : mettre à jour les deux lignes
  `CFBundleShortVersionString` et `CFBundleVersion`.
- Commit : `chore(release): X.Y.Z` (uniquement `build-app.sh`).

### 7b. Tag
- `git tag vX.Y.Z` (tag léger, cohérent avec l'historique existant).

### 8b. Push
- `git push origin main`
- `git push origin vX.Y.Z`

### 9b. Déploiement local (remplace l'app actuelle)
- `./Scripts/build-app.sh`
- Vérifier la sortie : doit finir par `✅ Installé : …/Potof Toolkit.app`.
- Confirmer la version installée :
  `defaults read "$HOME/Applications/Potof Toolkit.app/Contents/Info.plist" CFBundleShortVersionString`
  (doit renvoyer `X.Y.Z`).

### 10b. Compte rendu
Résumer : version publiée, tag, lien commit/tag (`origin`), chemin de l'app installée.

## Gotchas
- **Hors `main`** : review / commit / push **uniquement**. Jamais de tag ni de
  `build-app.sh` (déploiement) — cf. CLAUDE.md (« pas de déploiement sauvage » ; hors
  `main` = pas de déploiement dans `~/Applications`).
- **App en cours d'exécution** (mode `main`) : `build-app.sh` remplace le bundle sur
  disque, mais une instance déjà lancée continue de tourner sur l'ancienne. Pour basculer
  sur la nouvelle version, il faut **quitter puis relancer** l'app. ⚠️ Quitter tue les
  sessions Claude actives (l'app possède les process). **Ne pas forcer le quit sans
  prévenir** ; proposer le relaunch, laisser l'utilisateur choisir. Relance manuelle :
  `open -a "Potof Toolkit"`.
- **Push = irréversible** (surtout un tag public). C'est pourquoi les points de contrôle
  (4a / 5b) sont explicites. En cas d'erreur après push, ne pas réécrire l'historique
  sans demander.
- Bumper `CFBundleVersion` (l'entier) est **obligatoire** (mode `main`) : macOS s'en sert
  pour distinguer les builds ; deux releases avec le même build number sèment la confusion
  dans Launch Services.
- Le tag et le bump `build-app.sh` doivent **toujours coïncider** : `vX.Y.Z` ⇔
  `CFBundleShortVersionString = X.Y.Z`.
