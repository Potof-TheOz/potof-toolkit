import SwiftUI

/// Marque « burst » de Claude, rendue depuis son tracé SVG mono-couleur.
///
/// Traduite en `Path` SwiftUI plutôt que chargée comme image : net à toute taille,
/// **aucune ressource à charger au runtime** (donc pas de `Bundle.module`, qui
/// `fatalError` en app bundlée — cf. invariant `CLAUDE.md`). Marche identiquement
/// en `swift run` et en `.app`.
struct ClaudeMarkShape: Shape {
    /// Tracé SVG officiel de la marque (viewBox `0 0 24 24`) — source de vérité,
    /// tel que fourni. Une seule couleur (le terracotta `Color.claudeBrand`).
    private static let svgPathData =
        "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    /// Tracé parsé une seule fois, en espace viewBox (0…24).
    private static let unitPath: Path = parse(svgPathData)

    func path(in rect: CGRect) -> Path {
        // Aspect-fit du viewBox 24×24 dans `rect`, centré.
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width  - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        let transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
        return Self.unitPath.applying(transform)
    }

    // MARK: - Parseur SVG (sous-ensemble M/L/H/V/C/Z, absolu + relatif)

    private enum Tok { case cmd(Character); case num(Double) }

    private static func parse(_ d: String) -> Path {
        var path = Path()
        let tokens = tokenize(d)
        var i = 0
        var cx: CGFloat = 0, cy: CGFloat = 0   // point courant
        var sx: CGFloat = 0, sy: CGFloat = 0   // début du sous-tracé (pour Z)
        var cmd: Character = " "

        func num() -> CGFloat {
            guard i < tokens.count, case let .num(v) = tokens[i] else { return 0 }
            i += 1
            return CGFloat(v)
        }

        while i < tokens.count {
            let before = i
            if case let .cmd(c) = tokens[i] { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            switch String(cmd).uppercased() {
            case "M":
                var x = num(); var y = num()
                if rel { x += cx; y += cy }
                cx = x; cy = y; sx = x; sy = y
                path.move(to: CGPoint(x: x, y: y))
                cmd = rel ? "l" : "L"   // les paires suivantes sont des lineto implicites
            case "L":
                var x = num(); var y = num()
                if rel { x += cx; y += cy }
                cx = x; cy = y
                path.addLine(to: CGPoint(x: x, y: y))
            case "H":
                var x = num()
                if rel { x += cx }
                cx = x
                path.addLine(to: CGPoint(x: x, y: cy))
            case "V":
                var y = num()
                if rel { y += cy }
                cy = y
                path.addLine(to: CGPoint(x: cx, y: y))
            case "C":
                var x1 = num(); var y1 = num()
                var x2 = num(); var y2 = num()
                var x = num();  var y = num()
                if rel { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy }
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
                cx = x; cy = y
            case "Z":
                path.closeSubpath()
                cx = sx; cy = sy
            default:
                break
            }
            // Garantit la progression : un nombre orphelin (ex. après un « Z », ou un
            // caractère inattendu) ne consommant rien ci-dessus sortirait en boucle.
            if i == before { i += 1 }
        }
        return path
    }

    /// Découpe le `d` en commandes (lettres) et nombres. Règle SVG : un second `.`
    /// ou un `-` (hors exposant) démarre un nouveau nombre (« .686.0608 » → 0.686, 0.0608).
    private static func tokenize(_ d: String) -> [Tok] {
        var out: [Tok] = []
        let chars = Array(d)
        var i = 0
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                i += 1; continue
            }
            if c.isLetter {
                out.append(.cmd(c)); i += 1; continue
            }
            var j = i
            if chars[j] == "-" || chars[j] == "+" { j += 1 }
            var sawDot = false
            while j < chars.count {
                let d2 = chars[j]
                if isDigit(d2) { j += 1 }
                else if d2 == "." && !sawDot { sawDot = true; j += 1 }
                else if d2 == "e" || d2 == "E" {
                    // Exposant `e[±]chiffres` — consommé seulement si des chiffres
                    // suivent (sinon un « e » isolé reste une lettre = commande).
                    var k = j + 1
                    if k < chars.count && (chars[k] == "+" || chars[k] == "-") { k += 1 }
                    guard k < chars.count && isDigit(chars[k]) else { break }
                    j = k + 1
                    while j < chars.count && isDigit(chars[j]) { j += 1 }
                    break   // l'exposant clôt le nombre
                }
                else { break }
            }
            if let v = Double(String(chars[i..<j])) { out.append(.num(v)) }
            i = max(j, i + 1)   // garde-fou anti-boucle sur caractère inattendu
        }
        return out
    }
}

/// La marque Claude prête à poser (couleur de marque). Dimensionner via `.frame`.
struct ClaudeMark: View {
    var body: some View {
        ClaudeMarkShape().fill(Color.claudeBrand)
    }
}

extension Color {
    /// Terracotta de la marque Claude (`#D97757`), tel que fourni dans le SVG.
    static let claudeBrand = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
}
