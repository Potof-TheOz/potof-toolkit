import Foundation

/// Un bloc de conflit d'un fichier, délimité par `<<<<<<<` … `=======` … `>>>>>>>`
/// (et éventuellement `|||||||` pour le style diff3, la version « base »).
struct ConflictHunk: Identifiable, Equatable {
    /// Choix de résolution du bloc.
    enum Choice: Equatable { case unresolved, ours, theirs, oursThenTheirs, theirsThenOurs }

    let id: Int
    /// Étiquette de « notre » côté (ex. `HEAD`) et du « leur » (ex. `origin/main`).
    let oursLabel: String
    let theirsLabel: String
    let ours: [String]
    /// Version commune (diff3), ou `nil` en style classique.
    let base: [String]?
    let theirs: [String]
    var choice: Choice = .unresolved

    /// Lignes retenues selon le choix, ou `nil` si le bloc n'est pas résolu.
    var resolvedLines: [String]? {
        switch choice {
        case .unresolved:     return nil
        case .ours:           return ours
        case .theirs:         return theirs
        case .oursThenTheirs: return ours + theirs
        case .theirsThenOurs: return theirs + ours
        }
    }
}

/// Segment d'un fichier en conflit : texte normal, ou bloc de conflit. `id` unique sur tout
/// le fichier (pas de collision entre index de texte et de conflit → `ForEach` sûr).
enum ConflictSegment: Identifiable {
    case text(id: Int, lines: [String])
    case conflict(id: Int, hunk: ConflictHunk)

    var id: Int {
        switch self {
        case .text(let id, _):     return id
        case .conflict(let id, _): return id
        }
    }
}

/// Un fichier en conflit : chemin + segments (dont les blocs à résoudre).
struct ConflictFile {
    let path: String
    var segments: [ConflictSegment]
    /// Le contenu original se terminait-il par un saut de ligne ? (pour reconstruire fidèle)
    let trailingNewline: Bool

    var hunks: [ConflictHunk] {
        segments.compactMap { if case .conflict(_, let h) = $0 { return h } else { return nil } }
    }
    var isFullyResolved: Bool { !hunks.isEmpty && hunks.allSatisfy { $0.choice != .unresolved } }

    /// Reconstruit le contenu résolu, ou `nil` si un bloc reste non résolu.
    func resolvedContent() -> String? {
        guard isFullyResolved else { return nil }
        var out: [String] = []
        for seg in segments {
            switch seg {
            case .text(_, let lines):  out.append(contentsOf: lines)
            case .conflict(_, let h):  out.append(contentsOf: h.resolvedLines ?? [])
            }
        }
        var text = out.joined(separator: "\n")
        if trailingNewline { text += "\n" }
        return text
    }

    /// Contenu brut avec marqueurs (pour l'édition manuelle libre).
    func rawContent() -> String {
        var out: [String] = []
        for seg in segments {
            switch seg {
            case .text(_, let lines): out.append(contentsOf: lines)
            case .conflict(_, let h):
                out.append("<<<<<<< \(h.oursLabel)")
                out.append(contentsOf: h.ours)
                out.append("=======")
                out.append(contentsOf: h.theirs)
                out.append(">>>>>>> \(h.theirsLabel)")
            }
        }
        var text = out.joined(separator: "\n")
        if trailingNewline { text += "\n" }
        return text
    }

    mutating func setChoice(_ choice: ConflictHunk.Choice, forHunk hunkID: Int) {
        segments = segments.map { seg in
            if case .conflict(let sid, var h) = seg, h.id == hunkID {
                h.choice = choice
                return .conflict(id: sid, hunk: h)
            }
            return seg
        }
    }
}

enum ConflictParser {
    /// Parse le contenu d'un fichier en conflit en segments texte / conflit.
    static func parse(path: String, content: String) -> ConflictFile {
        let trailingNewline = content.hasSuffix("\n")
        var lines = content.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }   // enlève l'artefact de fin de split

        var segments: [ConflictSegment] = []
        var segID = 0
        var hunkID = 0
        var textBuffer: [String] = []

        func flushText() {
            if !textBuffer.isEmpty {
                segments.append(.text(id: segID, lines: textBuffer)); segID += 1
                textBuffer = []
            }
        }

        var i = 0
        while i < lines.count {
            let l = lines[i]
            guard l.hasPrefix("<<<<<<<") else { textBuffer.append(l); i += 1; continue }

            flushText()
            let oursLabel = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            var ours: [String] = [], theirs: [String] = []
            var base: [String]? = nil
            i += 1
            while i < lines.count, !lines[i].hasPrefix("|||||||"), !lines[i].hasPrefix("=======") {
                ours.append(lines[i]); i += 1
            }
            if i < lines.count, lines[i].hasPrefix("|||||||") {
                var b: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("=======") { b.append(lines[i]); i += 1 }
                base = b
            }
            if i < lines.count, lines[i].hasPrefix("=======") { i += 1 }
            var theirsLabel = ""
            while i < lines.count, !lines[i].hasPrefix(">>>>>>>") { theirs.append(lines[i]); i += 1 }
            if i < lines.count, lines[i].hasPrefix(">>>>>>>") {
                theirsLabel = String(lines[i].dropFirst(7)).trimmingCharacters(in: .whitespaces)
                i += 1
            }

            let hunk = ConflictHunk(
                id: hunkID,
                oursLabel: oursLabel.isEmpty ? "notre version" : oursLabel,
                theirsLabel: theirsLabel.isEmpty ? "leur version" : theirsLabel,
                ours: ours, base: base, theirs: theirs
            )
            segments.append(.conflict(id: segID, hunk: hunk)); segID += 1; hunkID += 1
        }
        flushText()

        return ConflictFile(path: path, segments: segments, trailingNewline: trailingNewline)
    }
}
