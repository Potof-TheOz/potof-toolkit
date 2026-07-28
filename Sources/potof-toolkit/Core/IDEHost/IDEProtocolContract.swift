import Foundation

/// **Le contrat protocolaire `claude` ↔ IDE, en un seul endroit.**
///
/// Le protocole d'intégration IDE de Claude Code n'est pas documenté : tout ce qui
/// suit a été **vérifié dans le binaire** (`~/.local/share/claude/versions/2.1.220`,
/// Mach-O bun). Les noms de symboles minifiés cités permettent de re-vérifier point
/// par point à chaque montée de version — c'est la raison d'être de ce fichier :
/// une seule surface à re-valider, plutôt que des chaînes littérales éparpillées.
///
/// Vue d'ensemble de la séquence (`Jbd`, `tSd`, `kq_`/`Aq_`/`Rq_`) :
/// ```
/// → tools/call openDiff { old_file_path, new_file_path (=même), new_file_contents, tab_name }   BLOQUANT
/// ← result.content = [...]        ← les fabriques ci-dessous
///     puis, côté CLI :  hunks = diff(oldContent, newContent)
///                       hunks.isEmpty ? deny("User denied via IDE") : allow(updatedInput)
/// ```
/// **Conséquence structurante** : le panneau de diff **EST** le prompt de permission.
/// Quand la réponse est bien formée, aucun prompt n'apparaît dans le terminal — il ne
/// faut donc **jamais** y envoyer un « Entrée » à l'aveugle. Et le contenu renvoyé
/// devient l'input réel de l'outil `Edit`/`Write` : accepter en modifiant est légitime.
///
/// Éligibilité (`eSd`, pour mémoire — ce que le pont ne couvrira jamais) : seuls
/// `Edit` et `Write`, hors `.ipynb`, et seulement si `settings.diffTool == "auto"`
/// et qu'un client `name == "ide"` est connecté. Bash, NotebookEdit, outils MCP,
/// sortie de plan mode… continuent de passer par le prompt du terminal.
enum IDEProtocolContract {

    /// Version de `claude` contre laquelle ce contrat a été re-vérifié (2026-07-28).
    /// `IDEContractGuard` la compare à la version réellement installée pour lever un
    /// avertissement **informatif** (le signal faisant autorité reste la vérification
    /// post-acceptation sur disque, indépendante de la version).
    static let lastValidatedClaudeVersion = "2.1.220"

    /// Nom annoncé dans le lock (`ideName`) et affiché par la commande `/ide`.
    /// Sert aussi de discriminant pour ne balayer que **nos** locks orphelins.
    static let ideName = "Potof Toolkit"

    /// En-tête d'authentification exigé au handshake, **déjà en minuscules** (les
    /// en-têtes HTTP sont insensibles à la casse et on normalise à la lecture ;
    /// `claude` l'émet en `X-Claude-Code-Ide-Authorization`, casse confirmée).
    /// La valeur attendue est l'`authToken` publié dans le lock.
    static let authHeaderLowercased = "x-claude-code-ide-authorization"

    /// Sous-protocole WebSocket exigé par le client, à **écho** dans la réponse 101 :
    /// sans lui, `claude` referme la connexion juste après l'upgrade.
    static let webSocketSubprotocol = "mcp"

    // MARK: - Formes de réponse à `openDiff`

    /// Acceptation = **DEUX** blocs de contenu.
    ///
    /// ⚠️ Vérifié dans le binaire 2.1.220 (`kq_`) :
    /// `content[0].text === "FILE_SAVED" && typeof content[1].text === "string"`.
    /// Avec **un seul** bloc, `content[1]` est `undefined` → `TypeError` côté CLI →
    /// catch → « Failed to show diff in IDE » : la revendication de permission n'est
    /// pas prise et **l'édition n'est jamais appliquée** (c'était le défaut D1).
    ///
    /// Le **2ᵉ bloc devient l'input réel** de l'outil : le CLI recalcule un hunk
    /// `old → final` avec un contexte de 1e5 lignes (`Idt(singleHunk:true)`), donc le
    /// hunk couvre tout le fichier. C'est ce qui rend « accepter en modifiant » sûr,
    /// y compris pour `Write`.
    /// Garde-fou connu : au-delà de ~100 000 lignes le diff se scinde et seul le
    /// premier hunk est repris → l'édition libre doit être désactivée à ce seuil.
    static func acceptedContent(_ finalContent: String) -> [[String: Any]] {
        [["type": "text", "text": "FILE_SAVED"],
         ["type": "text", "text": finalContent]]
    }

    /// Refus = un seul bloc `DIFF_REJECTED`. Le CLI pose alors `newContent = oldContent`
    /// (`tSd`), obtient un diff vide et transforme ça en `deny("User denied via IDE")`
    /// + annulation. Corollaire à afficher dans l'UI : **accepter un contenu édité
    /// redevenu identique à l'original équivaut à un refus.**
    static func rejectedContent() -> [[String: Any]] {
        [["type": "text", "text": "DIFF_REJECTED"]]
    }

    /// Réponse générique « un bloc texte » (les outils autres qu'`openDiff` :
    /// `TAB_CLOSED`, `CLOSED_n_DIFF_TABS`, payloads JSON de contexte…).
    static func textContent(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text]]
    }

    /// Accusé de réception de l'outil **`close_tab`**.
    ///
    /// ⚠️ Ne **jamais** s'en servir pour répondre à un `openDiff` : dans ce contexte-là
    /// le CLI interprète `TAB_CLOSED` comme « accepté **tel que proposé** » (§2.3) —
    /// une confusion de fabrique écrirait le fichier sans que personne n'ait validé.
    /// Le refus, c'est `rejectedContent()`, et rien d'autre.
    static func closedTabContent() -> [[String: Any]] {
        textContent("TAB_CLOSED")
    }

    /// Accusé de réception de l'outil **`closeAllDiffTabs`**, avec le **vrai** nombre
    /// d'aperçus fermés. La forme `CLOSED_<n>_DIFF_TABS` est celle qu'attend le CLI ;
    /// `n` n'a pas de conséquence fonctionnelle de son côté, mais renvoyer `0` en dur
    /// (ce que faisait le code d'origine) rend indétectable un écart de comptage entre
    /// ce que l'IDE croit afficher et ce que le CLI croit avoir ouvert.
    static func closedAllTabsContent(count: Int) -> [[String: Any]] {
        textContent("CLOSED_\(count)_DIFF_TABS")
    }

    // MARK: - Outils exposés au CLI

    /// Noms **exacts** des outils MCP appelés par `claude`, en un seul endroit : le
    /// dispatcher de `IDEConnection` et la déclaration `tools/list` ci-dessous doivent
    /// citer les mêmes chaînes. Une divergence produit le pire des symptômes — un outil
    /// annoncé mais jamais servi, donc un `tools/call` qui **n'obtient jamais de
    /// réponse** et un agent bloqué sans message d'erreur.
    ///
    /// ⚠️ La casse est hétérogène côté CLI (`openDiff` en camel, `close_tab` en snake) :
    /// c'est le protocole tel qu'il est, ne pas « harmoniser ».
    enum ToolName {
        static let openDiff = "openDiff"
        static let getDiagnostics = "getDiagnostics"
        static let getWorkspaceFolders = "getWorkspaceFolders"
        static let getOpenEditors = "getOpenEditors"
        static let getCurrentSelection = "getCurrentSelection"
        /// Variante émise par certaines versions du CLI ; même réponse que
        /// `getCurrentSelection`. Non déclarée dans `toolDefs` (le CLI l'appelle sans
        /// l'avoir vue), mais servie — un appel non servi bloque.
        static let getLatestSelection = "getLatestSelection"
        static let closeTab = "close_tab"
        static let closeAllDiffTabs = "closeAllDiffTabs"
    }

    /// Déclaration renvoyée à `tools/list`. Seul `openDiff` est « actif » ; les autres
    /// sont des stubs neutres que `claude` consomme pour du contexte (leur absence ne
    /// casse rien, mais les déclarer évite des allers-retours et des logs d'erreur).
    static let toolDefs: [[String: Any]] = [
        ["name": ToolName.openDiff, "description": "Open a diff for approval",
         "inputSchema": ["type": "object",
                         "properties": ["old_file_path": ["type": "string"],
                                        "new_file_path": ["type": "string"],
                                        "new_file_contents": ["type": "string"],
                                        "tab_name": ["type": "string"]],
                         "required": ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]]],
        ["name": ToolName.getDiagnostics, "description": "Get language diagnostics",
         "inputSchema": ["type": "object", "properties": ["uri": ["type": "string"]]]],
        ["name": ToolName.getWorkspaceFolders, "description": "Get workspace folders",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": ToolName.getOpenEditors, "description": "Get open editors",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": ToolName.getCurrentSelection, "description": "Get current selection",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": ToolName.closeTab, "description": "Close a tab",
         "inputSchema": ["type": "object", "properties": ["tab_name": ["type": "string"]],
                         "required": ["tab_name"]]],
        ["name": ToolName.closeAllDiffTabs, "description": "Close all diff tabs",
         "inputSchema": ["type": "object", "properties": [:]]],
    ]

    /// Traduit un verdict en tableau `content` MCP. Point de passage **unique** :
    /// c'est ici que se joue la conformité de l'acceptation (2 blocs).
    static func content(for verdict: IDEDiffVerdict) -> [[String: Any]] {
        switch verdict {
        case .saved(let content): return acceptedContent(content)
        case .rejected:           return rejectedContent()
        }
    }
}
