import Foundation

/// Une ligne du rendu **côte à côte** : ancien fichier à gauche, nouveau à droite.
/// Un côté peut être `nil` : ajout pur (pas d'ancien), suppression pure (pas de
/// nouveau), ou remplissage quand un bloc modifié a plus de lignes d'un côté.
struct SideBySideDiffRow: Identifiable {
    let id: Int
    let left: DiffLine?   // côté ancien : .context ou .removed (jamais .added)
    let right: DiffLine?  // côté nouveau : .context ou .added (jamais .removed)
}

enum SideBySideDiff {

    /// Apparie une séquence de `DiffLine` (ordre d'affichage unifié) en lignes côte à
    /// côte. On empile les `removed` à gauche et les `added` à droite jusqu'à la
    /// prochaine ligne de contexte (ou la fin), puis on vide les deux piles en les
    /// appariant par rang, le côté le plus court étant complété par des `nil`. Une
    /// ligne de contexte occupe une ligne à elle seule, identique des deux côtés.
    ///
    /// Seuls le contexte et la fin déclenchent un `flush` : une alternance
    /// `removed`/`added` au sein d'un même bloc reste correctement regroupée (tout
    /// l'ancien à gauche, tout le nouveau à droite), quel que soit l'ordre d'émission.
    ///
    /// `id` est un compteur de **ligne** (pas un `DiffLine.id`) car une ligne peut
    /// porter deux `DiffLine` distincts (retrait apparié à un ajout).
    static func pair(_ lines: [DiffLine]) -> [SideBySideDiffRow] {
        var rows: [SideBySideDiffRow] = []
        var leftBuf: [DiffLine] = []
        var rightBuf: [DiffLine] = []
        var id = 0

        func flush() {
            let n = max(leftBuf.count, rightBuf.count)
            for i in 0..<n {
                rows.append(SideBySideDiffRow(
                    id: id,
                    left:  i < leftBuf.count  ? leftBuf[i]  : nil,
                    right: i < rightBuf.count ? rightBuf[i] : nil))
                id += 1
            }
            leftBuf.removeAll(keepingCapacity: true)
            rightBuf.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.kind {
            case .removed: leftBuf.append(line)
            case .added:   rightBuf.append(line)
            case .context:
                flush()
                rows.append(SideBySideDiffRow(id: id, left: line, right: line))
                id += 1
            }
        }
        flush()
        return rows
    }
}
