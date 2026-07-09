import Foundation

/// Une ligne du diff unifié calculé, prête à l'affichage.
///
/// On produit un modèle *déjà rendu* (numéros de ligne inclus) plutôt que de
/// laisser la vue recalculer : le diff peut être lourd, la vue doit rester bête.
struct DiffLine: Identifiable {
    enum Kind { case context, added, removed }
    let id: Int              // index stable pour ForEach (0-based, dans l'ordre d'affichage)
    let kind: Kind
    let text: String         // contenu de la ligne, SANS le \n final
    let oldNumber: Int?      // n° de ligne (1-based) côté ancien fichier ; nil si `added`
    let newNumber: Int?      // n° de ligne (1-based) côté nouveau fichier ; nil si `removed`
}

/// Résultat complet d'un diff de fichier, avec métadonnées d'affichage.
struct FileDiff {
    let lines: [DiffLine]
    let addedCount: Int      // nombre de lignes `added`
    let removedCount: Int    // nombre de lignes `removed`
    let isNewFile: Bool      // l'ancien fichier n'existait pas → tout est ajout
    let isBinary: Bool       // ancien contenu non décodable en UTF-8 → aperçu impossible
}

enum DiffComputer {

    /// Plafond de cellules de la matrice de LCS `(m+1)·(n+1)`. Au-delà (~9M cases,
    /// ~72 Mo d'entiers) on saute la DP : coût qu'on refuse de payer pour un simple
    /// aperçu. On borne le PRODUIT (pas chaque côté) pour couvrir aussi le cas
    /// asymétrique « vieux fichier énorme × nouveau moyen ». Voir `computeMiddle`.
    private static let lcsCellCap = 9_000_000

    /// Lit l'ancien contenu depuis le disque (`oldPath`) et calcule le diff vs `newContent`.
    /// Gère : fichier absent (isNewFile), contenu binaire (isBinary).
    static func compute(oldPath: String, newContent: String) -> FileDiff {
        let fm = FileManager.default
        // Fichier absent → création : tout `newContent` est un ajout. On délègue au
        // cœur avec `oldContent=""` (le chemin normal produit alors des lignes `added`),
        // mais on marque `isNewFile` pour que l'UI puisse le signaler.
        guard fm.fileExists(atPath: oldPath) else {
            return compute(oldContent: "", newContent: newContent, isNewFile: true)
        }
        // On lit d'abord en `Data` : c'est le seul moyen de distinguer un texte UTF-8
        // d'un binaire (une image, un .zip…). Si la lecture échoue ou si le décodage
        // UTF-8 échoue, l'aperçu ligne-à-ligne n'a aucun sens → `isBinary`.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: oldPath)),
              let old = String(data: data, encoding: .utf8) else {
            return FileDiff(lines: [], addedCount: 0, removedCount: 0,
                            isNewFile: false, isBinary: true)
        }
        return compute(oldContent: old, newContent: newContent, isNewFile: false)
    }

    /// Cœur testable : diff entre deux textes déjà en mémoire.
    static func compute(oldContent: String, newContent: String, isNewFile: Bool) -> FileDiff {
        let old = splitLines(oldContent)
        let new = splitLines(newContent)

        // --- Rognage des extrémités communes -------------------------------
        // Le cas courant (Claude modifie 3 lignes dans un fichier de 800) doit être
        // quasi gratuit : les lignes identiques en tête et en queue sont forcément
        // du `context` (une LCS les rangerait de toute façon dans la sous-séquence
        // commune). On les met de côté AVANT la DP, ce qui réduit le milieu — donc
        // la matrice — à la seule zone qui a bougé.
        let oldCount = old.count, newCount = new.count
        var prefix = 0
        while prefix < oldCount, prefix < newCount, old[prefix] == new[prefix] {
            prefix += 1
        }
        // Le suffixe ne doit PAS empiéter sur le préfixe déjà consommé (bornes
        // `< oldCount - prefix` et `< newCount - prefix`), sinon on compterait deux
        // fois les mêmes lignes quand un côté est un préfixe strict de l'autre.
        var suffix = 0
        while suffix < oldCount - prefix, suffix < newCount - prefix,
              old[oldCount - 1 - suffix] == new[newCount - 1 - suffix] {
            suffix += 1
        }

        // --- Assemblage avec numérotation cohérente ------------------------
        // `oldNum`/`newNum` avancent en continu du début à la fin du fichier (le
        // préfixe démarre à 1) : après le préfixe puis le milieu, ils tombent
        // pile sur le premier numéro du suffixe. Un seul compteur `id` sérialise
        // l'ordre d'affichage.
        var lines: [DiffLine] = []
        var oldNum = 1, newNum = 1, id = 0
        var added = 0, removed = 0

        func emit(_ kind: DiffLine.Kind, _ text: String) {
            let oldN: Int?, newN: Int?
            switch kind {
            case .context: oldN = oldNum; newN = newNum; oldNum += 1; newNum += 1
            case .removed: oldN = oldNum; newN = nil;    oldNum += 1; removed += 1
            case .added:   oldN = nil;    newN = newNum; newNum += 1; added += 1
            }
            lines.append(DiffLine(id: id, kind: kind, text: text, oldNumber: oldN, newNumber: newN))
            id += 1
        }

        // Préfixe commun (context). old[i] == new[i] par construction.
        for i in 0..<prefix { emit(.context, old[i]) }

        // Milieu divergent : la seule zone qui nécessite un vrai diff.
        let oldMid = Array(old[prefix..<(oldCount - suffix)])
        let newMid = Array(new[prefix..<(newCount - suffix)])
        for (kind, text) in computeMiddle(oldMid, newMid) { emit(kind, text) }

        // Suffixe commun (context). Reprend là où le milieu s'est arrêté.
        for i in 0..<suffix { emit(.context, old[oldCount - suffix + i]) }

        return FileDiff(lines: lines, addedCount: added, removedCount: removed,
                        isNewFile: isNewFile, isBinary: false)
    }

    // MARK: - Découpe en lignes

    /// Découpe sur `"\n"` en supprimant la ligne vide finale induite par un `"\n"`
    /// terminal : `"a\nb\n"` et `"a\nb"` donnent tous deux `["a","b"]` (on ne veut
    /// pas d'une fausse ligne vide qui apparaîtrait comme un ajout/retrait fantôme).
    /// `""` → `[]` (fichier vide = zéro ligne, pas une ligne vide).
    private static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if s.hasSuffix("\n") { parts.removeLast() }   // la dernière est toujours "" ici
        return parts
    }

    // MARK: - Diff du milieu (LCS + garde-fou)

    /// Retourne la séquence `(kind, texte)` du milieu, dans l'ordre d'affichage.
    private static func computeMiddle(_ old: [String], _ new: [String]) -> [(DiffLine.Kind, String)] {
        let m = old.count, n = new.count
        if m == 0 && n == 0 { return [] }

        // Garde-fou mémoire : si la matrice `(m+1)·(n+1)` dépasse le plafond de
        // cellules, on dégrade proprement en « tout l'ancien supprimé puis tout le
        // nouveau ajouté » : le rendu reste correct (juste moins fin, sans
        // appariement des lignes communes), pour un coût O(m+n). Le test `m > cap/n`
        // équivaut à `m*n > cap` sans risque de dépassement d'entier.
        if m > 0, n > 0, m > lcsCellCap / n {
            var out: [(DiffLine.Kind, String)] = []
            out.reserveCapacity(m + n)
            for line in old { out.append((.removed, line)) }
            for line in new { out.append((.added, line)) }
            return out
        }

        // Programmation dynamique : dp[i][j] = longueur de la LCS de old[0..<i] et
        // new[0..<j]. On remplit toute la matrice (préfixes), puis on remonte. Si un
        // côté est vide (m==0 ⇒ tout ajout, n==0 ⇒ tout retrait), la matrice reste
        // nulle et le backtrack ci-dessous s'en sort seul — on saute donc les boucles
        // (une plage `1...0` planterait).
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m >= 1 && n >= 1 {
            for i in 1...m {
                for j in 1...n {
                    if old[i - 1] == new[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }

        // Backtrack depuis (m, n). On collecte à l'envers puis on renverse.
        // Convention d'égalité `dp[i][j-1] >= dp[i-1][j]` → on privilégie l'ajout
        // en marche arrière, ce qui place (après renversement) les `removed` AVANT
        // les `added` — l'ordre habituel d'un diff unifié.
        var out: [(DiffLine.Kind, String)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                out.append((.context, old[i - 1])); i -= 1; j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
                out.append((.added, new[j - 1])); j -= 1
            } else {
                out.append((.removed, old[i - 1])); i -= 1
            }
        }
        return out.reversed()
    }
}
