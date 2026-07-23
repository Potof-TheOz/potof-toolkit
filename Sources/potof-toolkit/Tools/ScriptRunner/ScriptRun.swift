import Foundation

/// Une exécution de script npm **possédée par l'app** : le script tourne dans un
/// shell hébergé par un PTY SwiftTerm embarqué. Contrairement aux sessions Claude,
/// un run **survit à la fin de son process** (terminal conservé, badge de statut)
/// jusqu'à sa fermeture manuelle. Jamais persisté.
struct ScriptRun: Identifiable, Hashable {
    let id: UUID
    /// Dossier du package d'où le script est lancé (cwd du shell).
    let packageDir: URL
    /// Nom du projet racine (affichage sidebar / header).
    let projectName: String
    let scriptName: String
    /// Commande affichée dans le header (ex. « pnpm run dev »).
    let commandLabel: String
    var status: Status

    enum Status: Hashable {
        case running
        /// Arrêt propre demandé (Ctrl-C envoyé), en attente de la mort du process.
        case stopping
        case exited(code: Int32?)
        case killed(signal: Int32)

        /// Vrai tant que le process (script ou shell) vit encore.
        var isActive: Bool {
            switch self {
            case .running, .stopping: return true
            case .exited, .killed: return false
            }
        }
    }

    var packageName: String { packageDir.lastPathComponent }

    static func == (lhs: ScriptRun, rhs: ScriptRun) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Décode le statut waitpid **brut** que SwiftTerm passe tel quel au delegate
    /// (`processTerminated(exitCode:)`) : « exit 1 » arrive comme `256` (1 << 8),
    /// un SIGKILL comme `9`. Exité normalement si `(raw & 0x7f) == 0` → code
    /// `(raw >> 8) & 0xff` ; sinon tué par le signal `raw & 0x7f`.
    static func decodeWaitStatus(_ raw: Int32?) -> Status {
        guard let raw else { return .exited(code: nil) }
        if (raw & 0x7f) == 0 { return .exited(code: (raw >> 8) & 0xff) }
        return .killed(signal: raw & 0x7f)
    }
}
