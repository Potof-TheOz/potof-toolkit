import Foundation

/// Représentation d'un **vrai** diff unifié git (`git diff`), par opposition au diff
/// recalculé en LCS de `DiffComputer` (qui sert au rendu mais **pas** au staging).
///
/// Ce modèle conserve les hunks avec leurs en-têtes `@@` et permet de **reconstruire un
/// patch applicable** (`git apply`) ne contenant qu'une sélection de lignes → c'est la
/// primitive du staging par hunk / par ligne.
///
/// Convention de reconstruction (comme `git add -p`) pour une sélection partielle :
/// - lignes de contexte : conservées ;
/// - `+` **non** sélectionnées : **retirées** du patch (pas ajoutées à la cible) ;
/// - `-` **non** sélectionnées : **converties en contexte** (la ligne existe encore côté
///   cible) ;
/// - les compteurs `@@ -a,b +c,d @@` sont **recalculés** en conséquence.
struct UnifiedFileDiff {
    /// Lignes d'en-tête (de `diff --git …` jusqu'à `+++ …` inclus). Recopiées telles quelles.
    let headerLines: [String]
    let hunks: [Hunk]
    /// Diff binaire (`Binary files … differ`) → pas de staging par ligne.
    let isBinary: Bool

    var isEmpty: Bool { hunks.isEmpty }

    /// Construit un patch minimal applicable ne contenant que les lignes de changement
    /// dont l'`id` est dans `selected`. Renvoie `nil` si la sélection ne contient aucune
    /// ligne de changement (rien à appliquer).
    func buildPatch(selecting selected: Set<Int>) -> String? {
        guard !isBinary else { return nil }
        var out = headerLines
        var any = false
        for hunk in hunks {
            guard let rebuilt = hunk.rebuilt(selecting: selected) else { continue }
            out.append(contentsOf: rebuilt)
            any = true
        }
        guard any else { return nil }
        // `git apply` attend une ligne finale : on termine par un saut de ligne.
        return out.joined(separator: "\n") + "\n"
    }

    /// Ids de toutes les lignes de changement (`+`/`-`) du diff : sélection « tout ».
    var allChangeIDs: Set<Int> {
        var ids: Set<Int> = []
        for hunk in hunks {
            for line in hunk.lines where line.kind != .context { ids.insert(line.id) }
        }
        return ids
    }
}

/// Un hunk (`@@ -oldStart,oldCount +newStart,newCount @@`) et ses lignes.
struct Hunk: Identifiable {
    let id: Int
    /// Ligne d'en-tête brute (avec l'éventuel titre de section après le second `@@`).
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [PatchLine]

    /// Au moins une ligne de changement (sinon rien à stager pour ce hunk).
    var hasChanges: Bool { lines.contains { $0.kind != .context } }

    /// Reconstruit le hunk pour la sélection `selected` (voir `UnifiedFileDiff`). Renvoie
    /// `nil` si aucune ligne de changement de ce hunk n'est sélectionnée.
    func rebuilt(selecting selected: Set<Int>) -> [String]? {
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        var hasSelectedChange = false

        for line in lines {
            switch line.kind {
            case .context:
                body.append(" " + line.text)
                oldCount += 1; newCount += 1
                if line.noNewlineAfter { body.append(Self.noNewlineMarker) }
            case .added:
                if selected.contains(line.id) {
                    body.append("+" + line.text)
                    newCount += 1
                    hasSelectedChange = true
                    if line.noNewlineAfter { body.append(Self.noNewlineMarker) }
                }
                // non sélectionnée → disparaît du patch (ni dans l'ancien, ni le nouveau)
            case .removed:
                if selected.contains(line.id) {
                    body.append("-" + line.text)
                    oldCount += 1
                    hasSelectedChange = true
                    if line.noNewlineAfter { body.append(Self.noNewlineMarker) }
                } else {
                    // non sélectionnée → la ligne reste présente côté cible : contexte.
                    body.append(" " + line.text)
                    oldCount += 1; newCount += 1
                    if line.noNewlineAfter { body.append(Self.noNewlineMarker) }
                }
            }
        }
        guard hasSelectedChange else { return nil }
        // `oldStart`/`newStart` restent ceux du hunk d'origine ; seuls les comptes changent.
        let rebuiltHeader = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return [rebuiltHeader] + body
    }

    static let noNewlineMarker = "\\ No newline at end of file"
}

/// Une ligne d'un hunk. `raw` n'est pas conservé : on reconstruit à partir de `kind`+`text`.
struct PatchLine: Identifiable {
    enum Kind { case context, added, removed }
    let id: Int
    let kind: Kind
    /// Contenu **sans** le préfixe (`+`/`-`/espace) ni le `\n`.
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// La ligne source est-elle suivie d'un `\ No newline at end of file` ?
    var noNewlineAfter: Bool

    /// Adaptation vers le modèle de rendu partagé `DiffLine` (→ `DiffLineRow`).
    var asDiffLine: DiffLine {
        let k: DiffLine.Kind
        switch kind {
        case .context: k = .context
        case .added:   k = .added
        case .removed: k = .removed
        }
        return DiffLine(id: id, kind: k, text: text, oldNumber: oldNumber, newNumber: newNumber)
    }
}

enum UnifiedDiffParser {

    /// Parse la sortie d'un `git diff [--cached] --no-color -- <fichier>` (un seul fichier).
    static func parse(_ raw: String) -> UnifiedFileDiff {
        let rawLines = raw.components(separatedBy: "\n")
        var headerLines: [String] = []
        var hunks: [Hunk] = []
        var isBinary = false
        var lineID = 0
        var hunkID = 0

        var i = 0
        // En-tête : tout jusqu'au premier `@@`.
        while i < rawLines.count {
            let l = rawLines[i]
            if l.hasPrefix("@@") { break }
            if l.hasPrefix("Binary files ") || l.hasPrefix("GIT binary patch") { isBinary = true }
            headerLines.append(l)
            i += 1
        }

        // Hunks.
        while i < rawLines.count {
            let header = rawLines[i]
            guard header.hasPrefix("@@") else { i += 1; continue }
            let range = parseHunkHeader(header) ?? (0, 0, 0, 0)
            i += 1

            var lines: [PatchLine] = []
            var oldNum = range.oldStart
            var newNum = range.newStart

            loop: while i < rawLines.count {
                let l = rawLines[i]
                if l.hasPrefix("@@") || l.hasPrefix("diff --git") { break }
                if l.hasPrefix("\\") {                       // "\ No newline at end of file"
                    if !lines.isEmpty { lines[lines.count - 1].noNewlineAfter = true }
                    i += 1
                    continue
                }
                guard let marker = l.first else {            // "" = artefact de fin de split
                    i += 1
                    continue
                }
                let text = String(l.dropFirst())
                switch marker {
                case "+":
                    lines.append(PatchLine(id: lineID, kind: .added, text: text,
                                           oldNumber: nil, newNumber: newNum, noNewlineAfter: false))
                    newNum += 1; lineID += 1
                case "-":
                    lines.append(PatchLine(id: lineID, kind: .removed, text: text,
                                           oldNumber: oldNum, newNumber: nil, noNewlineAfter: false))
                    oldNum += 1; lineID += 1
                case " ":
                    lines.append(PatchLine(id: lineID, kind: .context, text: text,
                                           oldNumber: oldNum, newNumber: newNum, noNewlineAfter: false))
                    oldNum += 1; newNum += 1; lineID += 1
                default:
                    break loop                                // ligne inattendue → fin du hunk
                }
                i += 1
            }

            hunks.append(Hunk(id: hunkID, header: header,
                              oldStart: range.oldStart, oldCount: range.oldCount,
                              newStart: range.newStart, newCount: range.newCount,
                              lines: lines))
            hunkID += 1
        }

        return UnifiedFileDiff(headerLines: headerLines, hunks: hunks, isBinary: isBinary)
    }

    /// `@@ -oldStart[,oldCount] +newStart[,newCount] @@ [section]`
    static func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard header.hasPrefix("@@") else { return nil }
        let afterFirst = header.dropFirst(2)
        guard let secondAt = afterFirst.range(of: "@@") else { return nil }
        let spec = afterFirst[..<secondAt.lowerBound].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: " ")
        guard parts.count == 2,
              parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
              let old = parseRange(parts[0].dropFirst()),
              let new = parseRange(parts[1].dropFirst())
        else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    /// `start` ou `start,count` (count implicite = 1).
    private static func parseRange<S: StringProtocol>(_ s: S) -> (start: Int, count: Int)? {
        let comps = s.split(separator: ",")
        if comps.count == 1, let start = Int(comps[0]) { return (start, 1) }
        if comps.count == 2, let start = Int(comps[0]), let count = Int(comps[1]) { return (start, count) }
        return nil
    }
}
