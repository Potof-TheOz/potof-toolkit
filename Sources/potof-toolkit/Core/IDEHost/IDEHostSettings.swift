import Foundation
import Combine

/// Périmètre servi par l'hôte IDE — autrement dit ce qu'on écrit dans
/// `workspaceFolders` du lock `~/.claude/ide/<port>.lock`.
///
/// **Pourquoi c'est réglable** (et pas une constante `$HOME`) : le matching côté
/// `claude` se fait par **préfixe de chemin**, et le CLI ne s'auto-connecte que s'il
/// trouve **exactement un** IDE valide pour son `cwd` (vérifié en 2.1.220, cf.
/// `IDEProtocolContract`). Deux IDE qui publient tous les deux un lock couvrant le même
/// dossier ⇒ **aucune** auto-connexion, ni vers l'un ni vers l'autre : il faut taper
/// `/ide` à la main. Un lock sur tout `$HOME` attrape donc *tous* les agents du poste —
/// c'est le but — mais entre en collision avec n'importe quel autre IDE qui
/// réapparaîtrait (WebStorm, VS Code, Cursor…). Ce réglage est l'amortisseur : rétrécir
/// le périmètre, voire couper, **sans recompiler**.
enum IDEHostScope: String, CaseIterable, Identifiable {

    /// Tout le dossier utilisateur. Défaut : couvre les worktrees Superset **et** tous
    /// les terminaux du poste. Contrepartie assumée : plus aucun autre IDE ne doit
    /// publier de lock (cf. §4 de `PLAN_IDE_HOST.md`).
    case allHome

    /// `~/.superset/worktrees` seulement. Repli sûr : **aucun** IDE classique n'ouvre
    /// jamais un projet dans cette arborescence (elle est créée et pilotée par
    /// Superset), donc zéro conflit possible — au prix des agents lancés depuis un
    /// terminal ordinaire, qui ne nous trouveront plus.
    case supersetWorktrees

    /// Aucun lock du tout : l'hôte s'arrête, plus personne ne nous découvre. Les agents
    /// externes retombent sur le **prompt de permission de leur terminal** (comportement
    /// natif de `claude`) — rien n'est cassé, la validation redevient simplement
    /// textuelle. Les sessions **possédées** par le Claude Launcher ne sont pas
    /// concernées : elles ont leur propre `IDEServer` avec port injecté.
    case disabled

    var id: String { rawValue }

    /// Libellé de menu.
    var title: String {
        switch self {
        case .allHome:            return "Tout le dossier utilisateur"
        case .supersetWorktrees:  return "Worktrees Superset uniquement"
        case .disabled:           return "Désactivé"
        }
    }

    /// Explication courte (infobulle de menu / panneau de diagnostic).
    var detail: String {
        switch self {
        case .allHome:
            return "Tous les agents lancés sous \(Self.home.path) se connectent à Potof. "
                + "Un autre IDE publiant un lock sur les mêmes dossiers neutraliserait "
                + "l'auto-connexion des deux côtés."
        case .supersetWorktrees:
            return "Seuls les agents lancés dans \(Self.supersetWorktreesFolder.path) se "
                + "connectent. Aucun IDE classique n'ouvre ces dossiers : zéro conflit."
        case .disabled:
            return "Aucun lock publié. Les agents externes retombent sur le prompt de "
                + "permission de leur terminal."
        }
    }

    /// Dossiers à publier dans `workspaceFolders`. **Vide = ne rien publier** (l'hôte
    /// s'arrête) : c'est la traduction directe de « désactivé », et le seul état où
    /// `IDEHost` ne doit pas avoir de listener.
    var servedFolders: [URL] {
        switch self {
        case .allHome:            return [Self.home]
        case .supersetWorktrees:  return [Self.supersetWorktreesFolder]
        case .disabled:           return []
        }
    }

    /// `true` si ce périmètre justifie un lock et un listener.
    var publishesLock: Bool { !servedFolders.isEmpty }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Le dossier n'a pas besoin d'exister : `claude` fait un `resolve()` du chemin
    /// déclaré puis un test de préfixe sur son `cwd`, sans jamais toucher au disque.
    /// On ne le crée donc pas (ce serait un effet de bord gratuit).
    private static var supersetWorktreesFolder: URL {
        home.appendingPathComponent(".superset/worktrees", isDirectory: true)
    }
}

/// **Réglages de l'hôte IDE**, persistés dans `UserDefaults` (domaine = bundle id, donc
/// dev et app bundlée ont deux stores distincts — cf. `docs/LIFECYCLE.md`).
///
/// Singleton : ces réglages pilotent un objet process-backed (`IDEHost`, ses sockets et
/// son lock sur disque). Ils ne doivent pas dépendre du cycle de vie d'une vue
/// (invariant du projet).
///
/// **Thread** : à lire et muter **sur le thread principal exclusivement** — muter
/// `scope` déclenche une republication du lock (E/S disque) et un `@Published`.
final class IDEHostSettings: ObservableObject {

    static let shared = IDEHostSettings()

    /// Clés `UserDefaults`. Préfixe `ideHost.` pour ne pas se mélanger aux réglages des
    /// outils (`claudeLauncher.*`, `scriptRunner.*`, `rootPath`).
    enum Key {
        static let scope = "ideHost.scope"
        static let activateOnRequest = "ideHost.activateOnRequest"
        static let requestTimeout = "ideHost.requestTimeout"
    }

    /// Périmètre servi. Changer cette valeur applique le nouveau périmètre **à chaud**
    /// (republication du lock, ou arrêt/démarrage de l'hôte) : c'est tout l'intérêt du
    /// réglage — pouvoir désamorcer un conflit d'IDE en un clic, sans quitter l'app ni
    /// perdre les connexions en cours.
    @Published var scope: IDEHostScope {
        didSet {
            guard scope != oldValue else { return }
            defaults.set(scope.rawValue, forKey: Key.scope)
            IDELog.log("réglages hôte IDE : périmètre → « \(scope.title) »")
            IDEHost.shared.applyCurrentScope()
        }
    }

    /// Passer l'app au premier plan quand une demande de revue arrive.
    ///
    /// Défaut **`false`**, volontairement : la demande vient d'un agent **externe** que
    /// l'utilisateur n'a pas forcément en tête à cet instant (il tape peut-être dans un
    /// autre outil). Voler le focus clavier lui ferait perdre des frappes. Par défaut la
    /// fenêtre de revue se contente donc d'un `orderFrontRegardless()`.
    ///
    /// Consommé par `Core/DiffReview/DiffReviewWindow.present()` : quand le drapeau est
    /// vrai, la fenêtre fait `NSApp.activate(ignoringOtherApps: true)` puis
    /// `makeKeyAndOrderFront(_:)` au lieu du simple `orderFrontRegardless()`. Pour qui
    /// préfère être interrompu : un agent bloqué sur un `openDiff` attend indéfiniment,
    /// et découvrir la pastille du Dock dix minutes plus tard est parfois pire.
    @Published var activateAppOnRequest: Bool {
        didSet {
            guard activateAppOnRequest != oldValue else { return }
            defaults.set(activateAppOnRequest, forKey: Key.activateOnRequest)
        }
    }

    /// Délai au bout duquel une demande non traitée serait automatiquement refusée.
    ///
    /// Défaut **`nil` = aucune expiration**, et c'est un choix, pas un oubli : côté CLI
    /// `openDiff` est un appel **bloquant**, donc expirer signifierait renvoyer un
    /// `DIFF_REJECTED` **dans le dos de l'utilisateur** — une modification refusée sans
    /// que personne ne l'ait vue, et un agent qui repart sur une base fausse. On préfère
    /// qu'un agent attende indéfiniment : la demande reste visible (compteur
    /// d'ancienneté dans la vue de revue, bannière), et l'utilisateur tranche quand il
    /// veut. Le réglage n'existe que comme échappatoire pour qui préfère l'inverse.
    ///
    /// ⚠️ **Publié mais pas appliqué ici** : le consommateur serait
    /// `Core/DiffReview/DiffReviewCenter` (il possède la file `pending` et les
    /// closures `complete`) — un timer par demande, résolvant en `.rejected` avec une
    /// trace dans `ide.log`.
    ///
    /// Persistance : absent ou `<= 0` ⇒ `nil` (les deux formes disent « aucune »).
    @Published var requestTimeout: TimeInterval? {
        didSet {
            guard requestTimeout != oldValue else { return }
            if let t = requestTimeout, t > 0 {
                defaults.set(t, forKey: Key.requestTimeout)
            } else {
                defaults.removeObject(forKey: Key.requestTimeout)
            }
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Affectations dans `init` : les `didSet` ne sont pas déclenchés, donc aucune
        // republication de lock ni écriture inutile à la construction du singleton.
        self.scope = (defaults.string(forKey: Key.scope).flatMap(IDEHostScope.init(rawValue:)))
            ?? .allHome     // valeur inconnue (réglage écrit à la main) ⇒ défaut
        self.activateAppOnRequest = defaults.bool(forKey: Key.activateOnRequest)   // absent ⇒ false
        // `object(forKey:)` et pas `double(forKey:)` : ce dernier rend `0` quand la clé
        // est absente, ce qui est indiscernable d'un « 0 seconde » explicite.
        let stored = defaults.object(forKey: Key.requestTimeout) as? Double
        self.requestTimeout = (stored.map { $0 > 0 ? $0 : nil } ?? nil)
    }

    /// Libellé lisible de l'expiration, pour le panneau de diagnostic.
    var requestTimeoutLabel: String {
        guard let t = requestTimeout, t > 0 else { return "aucune" }
        return t < 60
            ? "\(Int(t)) s"
            : "\(Int(t / 60)) min"
    }
}
