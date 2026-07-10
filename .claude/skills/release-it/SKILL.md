---
name: release-it
description: >-
  Coupe une release de Potof Toolkit de bout en bout : review du diff courant,
  commit(s) conventionnels, bump de version, commit chore(release), tag, push,
  puis déploiement local (remplace « Potof Toolkit.app » dans ~/Applications).
  À utiliser quand l'utilisateur veut « release », « livrer », « publier » ou
  « déployer l'app ».
---

# release-it — livrer Potof Toolkit

Pipeline de release complet. Objectif : passer du travail en cours (working tree)
à une app installée localement, taggée et poussée, en un geste.

## Contexte du repo (à connaître avant d'agir)

- **Version = source unique dans `Scripts/build-app.sh`** (pas de fichier `VERSION`,
  pas dans `Package.swift`). Deux clés à bumper ensemble dans le heredoc Info.plist :
  - `CFBundleShortVersionString` → version marketing `X.Y.Z` (ex. `1.2.1`).
  - `CFBundleVersion` → **entier monotone** incrémenté de +1 à chaque release (ex. `6` → `7`).
- **Convention** : commits conventionnels (`feat:`, `fix:`, `perf:`, `refactor:`,
  `chore:`…). La release elle-même est un commit **séparé** `chore(release): X.Y.Z`
  qui ne contient QUE le bump de `build-app.sh`.
- **Tag** : `vX.Y.Z` (préfixe `v`).
- **Branche** : les releases vont directement sur `main`. Remote : `origin`.
- **Deploy local** : `./Scripts/build-app.sh` compile en release, `rm -rf` l'ancien
  bundle et réinstalle `~/Applications/Potof Toolkit.app` (Launch Services réenregistré).
- Chaque commit git se termine par le trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## Étapes

### 1. État des lieux
- `git status` + `git diff` (et `git diff --staged`) pour voir tout le travail en cours.
- `git fetch origin` puis vérifier qu'on est sur `main` et **pas en retard** sur
  `origin/main` (`git status -sb`). Si en retard/divergent → **stop**, prévenir
  l'utilisateur (ne pas rebaser/merger de force).
- `git tag --sort=-v:refname | head -1` → dernière version publiée.
- S'il n'y a **rien à livrer** (working tree propre ET aucun commit local en avance
  sur `origin/main`) → le dire et s'arrêter.

### 2. Review (bloquant)
- Lancer le skill **`code-review`** sur le diff courant (working tree).
- Traiter les findings **CONFIRMED de correction** comme bloquants : les présenter,
  proposer un correctif, **ne pas continuer** tant qu'ils ne sont pas résolus ou que
  l'utilisateur ne demande pas explicitement de passer outre.
- Findings de style/simplification : les signaler, non bloquants.

### 3. Décider du bump de version
Depuis la dernière release, à partir des commits/diff à inclure :
- un `feat:` (ou plusieurs) sans breaking change → **minor** (`X.Y+1.0`) ;
- uniquement `fix:` / `perf:` / `refactor:` / `chore:`… → **patch** (`X.Y.Z+1`) ;
- un `BREAKING CHANGE` ou un `!` (ex. `feat!:`) → **major** (`X+1.0.0`).
`CFBundleVersion` = ancien + 1 dans tous les cas.
Annoncer le bump retenu (et le raisonnement) au point de contrôle.

### 4. Commit(s) du travail
- Regrouper le travail en cours en commit(s) conventionnels **au bon grain**
  (un sujet = un commit ; ex. `feat(notifications): …`). S'inspirer du style des
  messages récents (`git log --oneline -15`).
- Ne PAS inclure le bump de `build-app.sh` ici : il a son propre commit (étape 6).

### 5. Point de contrôle (confirmation unique)
Avant toute action irréversible (push, tag, remplacement de l'app), présenter un récap :
- version cible `X.Y.Z` (+ build number) et pourquoi ;
- liste des commits qui seront créés (messages) ;
- « je vais : commit → tag `vX.Y.Z` → push `main` + tag → remplacer l'app locale ».

Demander le feu vert. Si l'utilisateur a invoqué le skill avec une intention claire de
« va jusqu'au bout », enchaîner sans re-questionner à chaque sous-étape.

### 6. Bump + commit de release
- Éditer `Scripts/build-app.sh` : mettre à jour les deux lignes
  `CFBundleShortVersionString` et `CFBundleVersion`.
- Commit : `chore(release): X.Y.Z` (uniquement `build-app.sh`).

### 7. Tag
- `git tag vX.Y.Z` (tag léger, cohérent avec l'historique existant).

### 8. Push
- `git push origin main`
- `git push origin vX.Y.Z`

### 9. Déploiement local (remplace l'app actuelle)
- `./Scripts/build-app.sh`
- Vérifier la sortie : doit finir par `✅ Installé : …/Potof Toolkit.app`.
- Confirmer la version installée :
  `defaults read "$HOME/Applications/Potof Toolkit.app/Contents/Info.plist" CFBundleShortVersionString`
  (doit renvoyer `X.Y.Z`).

### 10. Compte rendu
Résumer : version publiée, tag, lien commit/tag (`origin`), chemin de l'app installée.

## Gotchas
- **App en cours d'exécution** : `build-app.sh` remplace le bundle sur disque, mais une
  instance déjà lancée continue de tourner sur l'ancienne. Pour basculer sur la nouvelle
  version, il faut **quitter puis relancer** l'app. ⚠️ Quitter tue les sessions Claude
  actives (l'app possède les process). **Ne pas forcer le quit sans prévenir** ;
  proposer le relaunch, laisser l'utilisateur choisir. Relance manuelle :
  `open -a "Potof Toolkit"`.
- **Push = irréversible** (surtout un tag public). C'est pourquoi l'étape 5 est un point
  de contrôle explicite. En cas d'erreur après push, ne pas réécrire l'historique sans
  demander.
- Bumper `CFBundleVersion` (l'entier) est **obligatoire** : macOS s'en sert pour
  distinguer les builds ; deux releases avec le même build number sèment la confusion
  dans Launch Services.
- Le tag et le bump `build-app.sh` doivent **toujours coïncider** : `vX.Y.Z` ⇔
  `CFBundleShortVersionString = X.Y.Z`.
