# Cycle de vie — build, run, deploy, debug

Complément de `CLAUDE.md`. Décrit comment développer, packager, déployer, débugger
Potof Toolkit, et où vivent les données / permissions.

Repères :
- **Produit / exécutable** : `potof-toolkit`
- **App bundlée** : `Potof Toolkit.app`
- **Bundle id** : `com.potof.potof-toolkit`
- **Install par défaut** : `~/Applications/Potof Toolkit.app`

---

## 1. Développement — `swift run`

```bash
swift build          # compiler seulement
swift run            # compiler + lancer (produit unique, pas besoin du nom)
```

- La fenêtre apparaît **au premier plan** (via `setActivationPolicy(.regular)` + `activate`).
- ⚠️ En `swift run`, l'exécutable est **nu** (dans `.build/…/debug/`) : **pas une `.app`**
  → invisible dans Spotlight, l'icône du Dock est posée au runtime via `Bundle.module`.
- ⚠️ **Infobulles (`.help`) absentes en `swift run`** : le panneau de tooltip macOS est
  supprimé pour un exécutable nu (non enregistré Launch Services). Elles s'affichent
  normalement en **app bundlée**. Le délai d'apparition est réglé à **512 ms** via
  `NSInitialToolTipDelay` (registré dans `AppDelegate`) — défaut macOS (~2 s) trop long.
- Domaine UserDefaults en dev : **`potof-toolkit`** (dérivé du nom de process).

Astuce : pour tuer une instance lancée en arrière-plan →
`pkill -f "\.build/.*potof-toolkit"`.

---

## 2. Packaging & installation — `./Scripts/build-app.sh`

```bash
./Scripts/build-app.sh                 # → ~/Applications
./Scripts/build-app.sh /Applications   # → /Applications (droits requis)
```

Le script enchaîne :
1. `swift build -c release`
2. assemble `Potof Toolkit.app` (binaire + `Info.plist` + resource bundle SPM copié dans
   `Contents/Resources/`)
3. génère `AppIcon.icns` avec `sips` + `iconutil` (tailles 16→1024) depuis
   `Sources/potof-toolkit/Resources/AppIcon.png`
4. **signe ad-hoc** (`codesign --force --deep --sign -`) — identité stable, sans certificat
5. installe dans le dossier cible
6. enregistre auprès de **Launch Services** (`lsregister -f`) pour Spotlight / `open -a`

Après ça : **Cmd+Espace → « Potof »**, ou `open -a "Potof Toolkit"`.

L'`Info.plist` porte notamment : `CFBundleIdentifier`, `CFBundleIconFile=AppIcon`,
`LSMinimumSystemVersion=13.0`.

> Dépendance : `swift build` récupère **SwiftTerm** (émulateur de terminal, MIT). SPM
> le **link statiquement** dans l'exécutable → aucun framework à copier dans le bundle,
> `build-app.sh` reste inchangé sur ce point.

---

## 3. Données & persistance

Le stockage `UserDefaults` est indexé par **domaine = bundle id (bundlée) / nom de process (dev)**.
Il y a donc **deux stores distincts** :

| Lancement    | Domaine                   | Fichier                                             |
|--------------|---------------------------|-----------------------------------------------------|
| `swift run`  | `potof-toolkit`           | `~/Library/Preferences/potof-toolkit.plist`         |
| App bundlée  | `com.potof.potof-toolkit` | `~/Library/Preferences/com.potof.potof-toolkit.plist` |

Clés stockées : **`rootPath`** (dossier racine) et **`claudeLauncher.favorites`** (tableau de
chemins absolus).

**Les rebuilds NE font PAS perdre les données.** `build-app.sh` réécrit uniquement le contenu
de la `.app` ; il ne touche jamais `~/Library/Preferences/`. Tant que le bundle id reste
`com.potof.potof-toolkit`, le plist survit à tous les rebuilds. Le seul « reset » est le
passage **dev ↔ bundlée** (deux domaines différents).

Inspection / maintenance :
```bash
defaults read   com.potof.potof-toolkit                 # tout voir
defaults read   com.potof.potof-toolkit claudeLauncher.favorites
defaults delete com.potof.potof-toolkit                 # tout réinitialiser
```

> Pour partager le même store entre dev et bundlée, il faudrait forcer un suite commun
> (`UserDefaults(suiteName: "com.potof.potof-toolkit")`) dans le code — non fait actuellement.

---

## 4. Permissions — sous-process & PTY (plus d'Automation)

- L'app **n'utilise plus Apple Events / Automation** : elle ne pilote plus iTerm2.
  `NSAppleEventsUsageDescription` a été retiré de l'`Info.plist`.
- Elle lance `claude` dans un **PTY** via SwiftTerm (`LocalProcessTerminalView`). Pour
  qu'un sous-process ait accès au disque et aux commandes, **l'App Sandbox doit rester
  désactivée** (cf. CLAUDE.md, invariant). Aucune autorisation TCC particulière n'est
  demandée pour ça.
- Selon les dossiers ouverts, macOS **peut** demander l'accès à des zones protégées
  (Bureau/Documents/Téléchargements) au premier accès — comportement standard, un clic.
- Nettoyer d'anciennes autorisations Automation résiduelles (versions iTerm2 précédentes) :
  ```bash
  tccutil reset AppleEvents com.potof.potof-toolkit
  ```

---

## 5. Icône

- Source : `Sources/potof-toolkit/Resources/AppIcon.png` — **1024×1024**, coins arrondis
  pré-cuits + coins transparents (le `.icns`/Dock l'affiche tel quel, sans arrondi ajouté).
- Contenu actuel : visage détouré (framework **Vision**) sur tuile dégradée bleue +
  lettrage « POTOF ».
- **Pour changer l'icône** : remplacer ce PNG (même format 1024×1024, coins transparents),
  puis `./Scripts/build-app.sh` (régénère le `.icns`). En `swift run`, l'icône est chargée
  via `Bundle.module` donc un simple rebuild suffit aussi.

---

## 6. Debugger

```bash
# Processus en cours
pgrep -fl potof-toolkit

# Logs (NSLog) — via unified logging
log stream --predicate 'process == "potof-toolkit"' --level debug

# Lancer la version bundlée depuis le terminal pour voir stdout/stderr directement
"$HOME/Applications/Potof Toolkit.app/Contents/MacOS/potof-toolkit"

# Vérifier l'enregistrement Launch Services / Spotlight
open -Ra "Potof Toolkit" && echo "trouvée"
mdfind -name "Potof Toolkit" | grep '\.app$'
```

---

## 7. Troubleshooting

- **`swift build` échoue avec `redefinition of module 'SwiftBridging'`, ou symboles
  `PackageDescription.Package.__allocating_init` introuvables au link** → **Command Line
  Tools corrompus** (déjà rencontré avec CLT 16.4 : modulemap dupliqué + `libPackageDescription.dylib`
  amputée du type `Package`). Correctif : réinstaller les CLT.
  ```bash
  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install
  ```
  (Diagnostic possible : `nm -a …/pm/ManifestAPI/libPackageDescription.dylib | grep 7PackageC`
  doit renvoyer des symboles ; 0 = dylib corrompue.)

- **L'app bundlée crashe au démarrage : `Fatal error: could not load resource bundle`**
  → `Bundle.module` ne trouve pas le resource bundle SPM. L'accessor généré par SwiftPM le
  cherche à `Bundle.main.bundleURL` (**racine du `.app`**, hors `Contents/`) puis, en repli,
  à un **chemin de build absolu figé** à la compilation. En bundle, le premier n'existe pas
  (on ne met rien à la racine, sinon `codesign` refuse : *unsealed contents present in the
  bundle root*) et le repli casse dès que le dépôt/`.build` bouge. **Correctif en place** :
  `applyDockIcon()` **n'appelle `Bundle.module` qu'en dev** (`guard bundleURL.pathExtension
  != "app"`) — l'app bundlée tire son icône du `.icns`. Ne pas réintroduire d'accès
  `Bundle.module` sur un chemin bundlé.

- **La fenêtre n'apparaît pas / ne prend pas le focus** → vérifier
  `setActivationPolicy(.regular)` + `activate(ignoringOtherApps: true)` dans `AppDelegate`.
  NB : en environnement multi-Spaces, la fenêtre peut s'ouvrir sur un **bureau (Space) non
  affiché** — l'app tourne bien (`pgrep -x potof-toolkit`), il suffit de Cmd-Tab dessus.

- **Le terminal reste vide / `claude: command not found`** → le login shell ne résout
  pas `claude`. Vérifier : `"$SHELL" -l -i -c 'command -v claude'`. Le PATH doit être
  posé par `.zprofile`/`.zshrc` (Homebrew, `~/.local/bin`…). On lance bien `$SHELL -l`
  (login) et non `claude` en direct (cf. `docs/SESSIONS.md`).

- **La commande `cd && claude` s'écrit avant le prompt** (machine lente) → augmenter le
  délai (~0,35 s) dans `TerminalController.start`.

- **Navigation qui « saute » / disposition instable** → ne PAS réintroduire
  `NavigationSplitView` (cf. invariants dans `CLAUDE.md`). La sélection d'outil est un
  menu dans le header fixe ; le split de l'outil est un `HSplitView` interne.

- **L'app n'apparaît pas dans Spotlight** → relancer `build-app.sh` (qui fait `lsregister -f`),
  ou forcer : `lsregister -f "$HOME/Applications/Potof Toolkit.app"`.
