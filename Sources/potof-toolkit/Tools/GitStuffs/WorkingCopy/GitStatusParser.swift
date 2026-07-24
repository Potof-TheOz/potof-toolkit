import Foundation

/// Parseurs **purs** (donc testables) des sorties `git status` / `rev-list`.
///
/// On utilise **porcelain v2** (`--porcelain=v2 -z`) plutôt que v1 : le format v2 est
/// **non ambigu** (champs explicites, chemin d'origine des renommages dans un champ
/// NUL-séparé dédié), là où l'ordre des chemins de renommage de v1 `-z` prête à confusion.
enum GitStatusParser {

    /// Parse la sortie de `git status --porcelain=v2 -z`.
    ///
    /// Enregistrements séparés par NUL. Un enregistrement de renommage/copie (type `2`)
    /// est **suivi d'un champ NUL supplémentaire** : le chemin d'origine. Les fichiers
    /// ignorés (`!`) sont écartés.
    static func parseStatus(_ raw: String) -> [FileStatus] {
        // `omittingEmptySubsequences: false` : on veut préserver l'indexation exacte des
        // champs (le champ d'origine d'un renommage suit immédiatement son enregistrement).
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var results: [FileStatus] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard let first = token.first else { i += 1; continue }
            switch first {
            case "1":
                if let fs = parseOrdinary(token) { results.append(fs) }
                i += 1
            case "2":
                // Le chemin d'origine est le token suivant.
                let orig = (i + 1 < tokens.count) ? tokens[i + 1] : nil
                if let fs = parseRename(token, origPath: orig) { results.append(fs) }
                i += 2
            case "u":
                if let fs = parseUnmerged(token) { results.append(fs) }
                i += 1
            case "?":
                let path = String(token.dropFirst(2))       // "? <path>"
                if !path.isEmpty {
                    results.append(FileStatus(path: path, originalPath: nil,
                                              indexStatus: "?", worktreeStatus: "?"))
                }
                i += 1
            default:                                          // "!" ignoré, ou bruit
                i += 1
            }
        }
        return results
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ token: String) -> FileStatus? {
        let parts = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { return nil }
        let xy = Array(parts[1])
        guard xy.count == 2 else { return nil }
        return FileStatus(path: String(parts[8]), originalPath: nil,
                          indexStatus: xy[0], worktreeStatus: xy[1])
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>` (+ origPath en champ suivant)
    private static func parseRename(_ token: String, origPath: String?) -> FileStatus? {
        let parts = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10 else { return nil }
        let xy = Array(parts[1])
        guard xy.count == 2 else { return nil }
        let orig = (origPath?.isEmpty == false) ? origPath : nil
        return FileStatus(path: String(parts[9]), originalPath: orig,
                          indexStatus: xy[0], worktreeStatus: xy[1])
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func parseUnmerged(_ token: String) -> FileStatus? {
        let parts = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11 else { return nil }
        let xy = Array(parts[1])
        guard xy.count == 2 else { return nil }
        return FileStatus(path: String(parts[10]), originalPath: nil,
                          indexStatus: xy[0], worktreeStatus: xy[1])
    }

    /// Parse `git rev-list --left-right --count @{upstream}...HEAD` → `behind<TAB>ahead`
    /// (gauche = commits de l'amont absents en local = retard ; droite = locaux = avance).
    static func parseAheadBehind(_ raw: String) -> (behind: Int, ahead: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return nil
        }
        return (behind, ahead)
    }
}
