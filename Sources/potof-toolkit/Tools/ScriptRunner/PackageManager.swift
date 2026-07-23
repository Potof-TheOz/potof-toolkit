import Foundation

/// Gestionnaire de paquets JS d'un projet, auto-détecté par **lockfile à la racine
/// du projet** (les lockfiles vivent à la racine des monorepos, pas dans les
/// workspaces).
enum PackageManager: String, CaseIterable {
    case npm
    case pnpm
    case yarn
    case bun

    /// Détection par lockfile : `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn,
    /// `bun.lockb`/`bun.lock` → bun, sinon npm (défaut universel).
    ///
    /// On regarde d'abord le **dossier du package** (un sous-dossier vendored —
    /// ex. `docs/` avec son propre `yarn.lock` dans un projet npm — a son propre
    /// gestionnaire), puis on retombe sur la **racine du projet** (cas monorepo :
    /// le lockfile ne vit qu'à la racine, pas dans chaque workspace).
    static func detect(packageDir: URL, projectRoot: URL) -> PackageManager {
        detectLockfile(in: packageDir) ?? detectLockfile(in: projectRoot) ?? .npm
    }

    /// Gestionnaire indiqué par un lockfile présent dans `dir`, ou `nil`.
    private static func detectLockfile(in dir: URL) -> PackageManager? {
        let fm = FileManager.default
        func exists(_ lockfile: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(lockfile).path)
        }
        if exists("pnpm-lock.yaml") { return .pnpm }
        if exists("yarn.lock") { return .yarn }
        // Bun : `bun.lockb` (binaire historique) ou `bun.lock` (texte, Bun ≥ 1.2).
        if exists("bun.lockb") || exists("bun.lock") { return .bun }
        return nil
    }

    /// Fragment de commande shell `<mgr> run '<script>'`, script échappé
    /// (apostrophe `'` → `'\''`, convention du projet). Le wrapper
    /// `cd '<dir>' && … ; exit` est ajouté par `ScriptTerminalController`.
    func runCommand(script: String) -> String {
        // Même échappement que `TerminalController.launchCommand` (esc).
        let escaped = script.replacingOccurrences(of: "'", with: "'\\''")
        return "\(rawValue) run '\(escaped)'"
    }
}
