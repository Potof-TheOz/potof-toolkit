import Foundation

/// Heuristiques de lecture de l'écran **rendu** de la TUI `claude` — chaînes repérées
/// empiriquement (contrat non officiel, cf. docs/IDE_BRIDGE.md). Centralisées ici pour
/// qu'un changement de formulation côté `claude` ne se corrige **qu'à un seul endroit** :
/// `SessionStore.confirmEditInTerminal` (répondre « Yes » au prompt) et
/// `InitClaudeMdCoordinator` (attendre que le prompt soit prêt) partageaient sinon les
/// mêmes littéraux dupliqués, et une mise à jour d'un seul côté aurait fait taper du
/// texte dans le mauvais contexte.
enum ClaudePromptHeuristics {

    /// Un **prompt de permission** est affiché
    /// (« Do you want to make this edit? 1. Yes / … »). Couvre aussi le prompt
    /// « trust this folder » (même forme numérotée « 1. Yes »).
    static func permissionPromptVisible(_ screen: String) -> Bool {
        screen.contains("Do you want")
            || screen.contains("make this edit")
            || screen.contains("1. Yes")
    }

    /// `claude` est **en train de travailler** (barre « esc to interrupt »).
    static func working(_ screen: String) -> Bool {
        screen.contains("to interrupt")
    }

    /// `claude` est **prêt à recevoir un prompt** : ni au travail, ni en attente d'une
    /// réponse à un prompt numéroté. NB : un shell nu (claude pas encore démarré) passe
    /// aussi ce test — les appelants ne doivent l'utiliser qu'une fois `claude` connu
    /// démarré (connexion du pont IDE).
    static func readyForInput(_ screen: String) -> Bool {
        !working(screen) && !permissionPromptVisible(screen)
    }
}
