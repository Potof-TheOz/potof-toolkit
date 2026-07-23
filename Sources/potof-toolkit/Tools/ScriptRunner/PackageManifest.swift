import Foundation

/// Un script npm d'un `package.json` (nom + commande, pour l'aperçu).
struct PackageScript: Identifiable, Hashable {
    let name: String
    let command: String
    var id: String { name }
}

/// Contenu utile d'un `package.json`. **Relu à chaud** à chaque affichage du
/// détail d'un package (les scripts changent souvent) — jamais mis en cache.
struct PackageManifest {
    /// Champ `name` du manifest (nil s'il est absent).
    let name: String?
    /// Scripts triés par nom — Foundation ne préserve pas l'ordre des clés JSON.
    let scripts: [PackageScript]

    /// Lit et parse `<dir>/package.json`. `nil` si le fichier est absent ou invalide.
    static func load(dir: URL) -> PackageManifest? {
        let fileURL = dir.appendingPathComponent("package.json")
        // Fichier absent ou illisible → pas de manifest.
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // JSON invalide ou racine non-objet → manifest inexploitable.
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else { return nil }

        // `name` : uniquement s'il est bien une String (un name non-String est ignoré).
        let name = object["name"] as? String

        // `scripts` : objet attendu ; on garde chaque paire dont la valeur est une
        // String (`compactMapValues`) au lieu d'exiger un `[String: String]` strict
        // — sinon une seule valeur non-String (ex. `"prepare": null`) ferait
        // disparaître TOUS les scripts. Absent ou non-objet → liste vide (le
        // manifest reste valide, il n'a juste rien à lancer).
        let scripts: [PackageScript]
        if let raw = object["scripts"] as? [String: Any] {
            scripts = raw
                .compactMapValues { $0 as? String }
                .map { PackageScript(name: $0.key, command: $0.value) }
                // Tri par nom : Foundation ne préserve pas l'ordre des clés JSON.
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else {
            scripts = []
        }

        return PackageManifest(name: name, scripts: scripts)
    }
}
