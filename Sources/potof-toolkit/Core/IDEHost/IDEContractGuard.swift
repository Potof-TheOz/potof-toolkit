import Foundation
import Combine

/// **Détecteur de dérive du contrat IDE.**
///
/// Le protocole `openDiff` n'est pas documenté : il peut changer à n'importe quelle
/// montée de version de `claude`. Le mode d'échec est vicieux — l'utilisateur clique
/// « Accepter », l'app est contente, et **rien n'est écrit** (c'est exactement ce que
/// produisait le défaut D1 : `FILE_SAVED` en un seul bloc → `TypeError` côté CLI).
/// Sans garde-fou, ça passe inaperçu.
///
/// Ce n'est pas une hypothèse : entre `claude 2.1.205` (version du spike) et `2.1.220`,
/// l'acceptation est passée de **un** à **deux** blocs de contenu. Pendant des mois,
/// l'app a cru accepter, le CLI levait une exception, retombait sur le prompt du
/// terminal — et **personne ne s'en est aperçu**, parce qu'un hack (« taper Entrée dans
/// le terminal 6 s plus tard ») masquait le symptôme. Ce fichier existe pour que la
/// prochaine dérive du même genre soit impossible à rater.
///
/// Deux signaux, de valeur très inégale :
/// 1. **Vérification post-acceptation** (fait autorité, indépendant de la version) :
///    après un `.saved(content:)`, relire le fichier pendant ≤ 3 s ; s'il ne converge
///    pas vers `content`, le contrat est rompu. C'est le seul signal qui ne suppose
///    rien du protocole : **l'app n'écrit jamais**, donc le fichier ne peut avoir
///    changé que parce que `claude` a bien reçu et compris notre acceptation.
/// 2. **Empreinte de version** (informatif) : la version annoncée au handshake,
///    comparée à `IDEProtocolContract.lastValidatedClaudeVersion` — un écart n'est
///    **pas** une panne (une version plus récente marche probablement très bien),
///    juste un contexte précieux le jour où une vraie dérive est détectée.
///
/// Doctrine anti-bruit : un bandeau qui se lève à tort est un bandeau qu'on n'ouvre
/// plus. Toutes les tolérances implémentées ici (course d'écriture, fichier resté
/// strictement identique = « non appliqué » et pas « protocole cassé ») existent pour
/// que le jour où il se lève, on le croie.
///
/// Singleton app-level observé par les vues (bandeau d'alerte) : l'état suit des
/// connexions vivantes, pas le cycle de vie d'une vue (invariant du projet).
final class IDEContractGuard: ObservableObject {

    static let shared = IDEContractGuard()

    /// Message à afficher en bandeau, `nil` si tout va bien. Une seule alerte à la
    /// fois : c'est un signal binaire « le pont ne fait plus ce qu'on croit ».
    @Published private(set) var warning: String?

    private init() {}

    // MARK: - Réglages de la vérification

    /// Budget de convergence. `claude` écrit le fichier juste après avoir reçu notre
    /// réponse ; en pratique c'est immédiat, 3 s couvrent très largement un gros
    /// fichier et une machine chargée sans laisser l'utilisateur dans le flou.
    private static let verificationWindow: TimeInterval = 3.0

    /// Sursis accordé **une seule fois** si, à l'échéance, le fichier contient un
    /// **préfixe strict** du contenu attendu : c'est une écriture visiblement en
    /// cours, pas une dérive. Borné, pour ne pas transformer l'attente en fuite.
    private static let writeInFlightGrace: TimeInterval = 1.5

    /// Cadence de relecture. Assez fin pour que le cas nominal se conclue en une ou
    /// deux itérations, assez lâche pour ne pas marteler le disque.
    private static let pollInterval: TimeInterval = 0.12

    // MARK: - État (muté **exclusivement** sur le thread principal)

    /// Version de `claude` annoncée par le dernier client connecté (`clientInfo`).
    /// Sert uniquement à enrichir le message quand une vraie dérive est détectée.
    private var observedClaudeVersion: String?

    /// File d'I/O dédiée : la relecture périodique dure jusqu'à ~4,5 s et touche le
    /// disque — elle n'a rien à faire sur le thread principal. Seule la publication
    /// de `warning` y revient.
    private let io = DispatchQueue(label: "com.potof.toolkit.ide-contract-guard",
                                   qos: .utility)

    // MARK: - 1. Vérification post-acceptation (le signal qui fait autorité)

    /// Arme la vérification après une acceptation : `path` doit converger vers
    /// `expected` dans les ~3 s (c'est `claude` qui écrit, pas nous).
    ///
    /// Appelable depuis n'importe quel thread : tout le travail part immédiatement
    /// sur `io`.
    func verifyAfterAccept(path: String, expected: String) {
        let expectedData = Data(expected.utf8)
        io.async { [weak self] in
            guard let self else { return }

            // Instantané de l'« avant ». Il sert à **discriminer** au moment du
            // diagnostic : un fichier resté strictement identique à cet instantané
            // n'est pas la même chose qu'un fichier écrit de travers (voir
            // `diagnose`). C'est la tolérance anti-faux-positif la plus importante
            // du fichier.
            let before = Self.read(path)

            // Course bénigne : `claude` peut avoir déjà écrit avant même notre
            // premier `read` (la réponse JSON-RPC est partie avant l'armement, et
            // l'écriture est locale). Convergence immédiate = cas nominal rapide.
            if before == expectedData {
                IDELog.log("contrat : acceptation appliquée d'emblée — "
                           + "\(Self.short(path)) (\(expectedData.count) o)")
                return
            }

            IDELog.log("contrat : vérification post-acceptation armée — "
                       + "\(Self.short(path)) attendu \(expectedData.count) o, "
                       + "actuel \(Self.describe(before))")
            self.poll(path: path, expected: expectedData, before: before,
                      deadline: Date().addingTimeInterval(Self.verificationWindow),
                      startedAt: Date(), graceUsed: false)
        }
    }

    /// Relecture périodique bornée. Ne conclut **jamais** en cours de route : un
    /// fichier momentanément absent (rename atomique : `unlink` puis `write`) ou
    /// tronqué (écriture par morceaux) est un état transitoire parfaitement normal.
    /// Seul l'état constaté à l'échéance compte.
    private func poll(path: String, expected: Data, before: Data?,
                      deadline: Date, startedAt: Date, graceUsed: Bool) {
        let current = Self.read(path)

        if current == expected {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            IDELog.log("contrat : acceptation appliquée en \(ms) ms — \(Self.short(path))")
            return
        }

        if Date() < deadline {
            io.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
                self?.poll(path: path, expected: expected, before: before,
                           deadline: deadline, startedAt: startedAt, graceUsed: graceUsed)
            }
            return
        }

        // Échéance atteinte. Dernière tolérance avant de crier : si ce qu'on lit est
        // un **préfixe strict** de l'attendu, l'écriture est manifestement en train
        // de se faire (gros fichier, disque lent) — on prolonge une fois, et une
        // seule.
        if !graceUsed, let current, current.count < expected.count,
           expected.starts(with: current) {
            IDELog.log("contrat : écriture en cours (\(current.count)/\(expected.count) o) "
                       + "— sursis de \(Self.writeInFlightGrace) s pour \(Self.short(path))")
            io.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
                self?.poll(path: path, expected: expected, before: before,
                           deadline: Date().addingTimeInterval(Self.writeInFlightGrace),
                           startedAt: startedAt, graceUsed: true)
            }
            return
        }

        diagnose(path: path, expected: expected, before: before, current: current)
    }

    /// Traduit un échec de convergence en une phrase honnête. Trois situations très
    /// différentes se cachent derrière « le fichier n'est pas ce qu'on attendait » :
    /// les confondre, c'est soit accuser à tort le protocole, soit rater une dérive.
    private func diagnose(path: String, expected: Data, before: Data?, current: Data?) {
        let name = Self.short(path)
        let window = Self.verificationWindow
        let reason: String

        if current == before {
            // **Non-application** : rien n'a bougé. C'est le symptôme de la dérive
            // D1… mais pas seulement. L'utilisateur peut avoir refusé l'édition au
            // niveau du CLI par un autre chemin (Échap / « no » sur un prompt de
            // permission resté actif, Ctrl-C, agent interrompu), ou l'outil peut
            // avoir échoué pour une raison locale (fichier en lecture seule, chemin
            // modifié entre-temps). On le dit tel quel plutôt que d'affirmer une
            // rupture de contrat qu'on n'a pas prouvée.
            if before == nil {
                reason = "L'acceptation n'a pas été appliquée : « \(name) » n'a toujours "
                    + "pas été créé \(Int(window)) s après validation."
            } else {
                reason = "L'acceptation n'a pas été appliquée : « \(name) » est resté "
                    + "inchangé \(Int(window)) s après validation."
            }
        } else if current == nil {
            // Le fichier a disparu et n'est jamais revenu : ni l'ancien, ni le
            // nouveau. Ça n'a rien de nominal.
            reason = "L'acceptation a laissé « \(name) » supprimé au lieu d'y écrire "
                + "le contenu validé."
        } else {
            // Le fichier a bougé, mais pas vers ce qu'on a validé. Soit `claude` a
            // appliqué autre chose que le contenu renvoyé (dérive du contrat : le
            // 2ᵉ bloc n'est plus l'input réel de l'outil), soit un tiers a écrit
            // par-dessus (formateur au save, autre agent sur le même fichier).
            reason = "Le contenu écrit dans « \(name) » ne correspond pas à ce qui a été "
                + "validé (\(Self.describe(current)) au lieu de \(expected.count) o)."
        }

        IDELog.log("contrat : DÉRIVE — \(reason) [avant \(Self.describe(before)), "
                   + "après \(Self.describe(current)), attendu \(expected.count) o]")
        flagDrift(reason)
    }

    // MARK: - 2. Empreinte de version (informatif, jamais bloquant)

    /// Enregistre la version de `claude` observée (premier `initialize`) et prévient
    /// si elle s'écarte de la dernière version validée.
    ///
    /// ⚠️ **N'affiche rien.** Une version plus récente n'est pas une panne — le pont
    /// a survécu à des dizaines de montées de version. Lever un bandeau à chaque
    /// `claude` mis à jour, c'est garantir que plus personne ne le lira le jour où il
    /// signalera une vraie rupture. On journalise, et on garde l'info sous le coude :
    /// `flagDrift` s'en sert pour transformer « ça ne marche pas » en « ça ne marche
    /// pas **et** tu tournes sur une version non validée », qui est actionnable.
    func noteClaudeVersion(_ version: String?) {
        onMain {
            let known = version?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let known, !known.isEmpty else {
                IDELog.log("contrat : version de claude non annoncée par le client")
                return
            }
            let changed = self.observedClaudeVersion != known
            self.observedClaudeVersion = known
            guard changed else { return }
            if known == IDEProtocolContract.lastValidatedClaudeVersion {
                IDELog.log("contrat : claude \(known) — version de référence du contrat")
            } else {
                IDELog.log("contrat : claude \(known) ≠ version validée "
                           + "\(IDEProtocolContract.lastValidatedClaudeVersion) — "
                           + "informatif, pas d'alerte (le juge de paix reste la "
                           + "vérification post-acceptation)")
            }
        }
    }

    // MARK: - 3. Point d'entrée public des autres détecteurs

    /// Lève le drapeau de dérive avec une raison lisible (journalisée dans `ide.log`).
    ///
    /// Appelé par la vérification post-acceptation ci-dessus, et par les détecteurs
    /// extérieurs — typiquement T7 : si un **prompt de permission apparaît dans le
    /// terminal** d'une session possédée alors que le panneau de diff est censé
    /// *être* la permission (§2.3 du contrat), c'est que notre réponse `openDiff` n'a
    /// pas été comprise. Même symptôme, même bandeau.
    ///
    /// `reason` doit être une phrase complète décrivant **ce qui a été constaté** ;
    /// cette méthode y ajoute le contexte de version et la sortie de secours.
    func flagDrift(_ reason: String) {
        onMain {
            let message = reason + " " + self.versionContext()
                + " Contrat, symptômes et procédure de re-validation : docs/IDE_BRIDGE.md"
                + " (auto-test : `potof-toolkit --ide-selftest --e2e`)."
            IDELog.log("contrat : bandeau levé — \(reason)")
            self.warning = message
        }
    }

    /// Le complément de phrase qui rend le message actionnable : quelle version de
    /// `claude` tourne réellement, et contre laquelle le contrat a été vérifié.
    private func versionContext() -> String {
        let validated = IDEProtocolContract.lastValidatedClaudeVersion
        guard let observed = observedClaudeVersion else {
            return "Version de claude inconnue (aucun client ne l'a annoncée) ; "
                + "le contrat a été vérifié contre \(validated)."
        }
        if observed == validated {
            return "claude \(observed) est bien la version contre laquelle le contrat "
                + "a été vérifié — la cause est donc ailleurs."
        }
        return "claude \(observed) est installé, alors que le contrat a été vérifié "
            + "contre \(validated) : le protocole IDE a probablement changé."
    }

    // MARK: - 4. Acquittement

    /// Efface l'alerte (acquittement par l'utilisateur).
    ///
    /// ⚠️ **Ne se réarme pas tout seul** : une acceptation qui réussit ensuite ne
    /// remet pas le bandeau, et une vérification réussie n'efface **pas** un bandeau
    /// existant. C'est délibéré et symétrique — un incident vu une fois doit rester
    /// visible jusqu'à ce qu'un humain le referme, sinon on retombe exactement dans
    /// le mode d'échec d'origine : une dérive intermittente qui s'auto-efface avant
    /// que quiconque l'ait lue. Seule une **nouvelle** détection (`flagDrift`) le
    /// relève.
    func clear() {
        onMain {
            guard self.warning != nil else { return }
            IDELog.log("contrat : bandeau acquitté par l'utilisateur")
            self.warning = nil
        }
    }

    // MARK: - Utilitaires

    /// Lecture non levante. `nil` = fichier absent/illisible — un état transitoire
    /// légitime pendant une écriture, jamais une conclusion en soi.
    private static func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// Taille lisible pour le log. **Jamais** le contenu : `ide.log` ne doit contenir
    /// ni source, ni secret, ni token (§7.4 du plan).
    private static func describe(_ data: Data?) -> String {
        guard let data else { return "absent" }
        return "\(data.count) o"
    }

    /// Nom de fichier seul dans les messages : le chemin absolu est déjà dans le log,
    /// et un bandeau de 200 caractères ne se lit pas.
    private static func short(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Publie sur le thread principal (mutation d'un `@Published`), **sans
    /// re-dispatcher** si on y est déjà — même patron que `DiffReviewCenter`.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
