import Foundation

enum MCPServerState: Equatable {
    case connected
    case needsAuth
    case failed(String)
}

/// Lecture de la sortie de `claude mcp list` (fonctions pures).
enum MCPList {

    static func parse(_ output: String) -> [String: MCPServerState] {
        var states: [String: MCPServerState] = [:]
        for raw in stripANSI(output).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains(" - ✔ ") || line.contains(" - ! ") || line.contains(" - ✘ "),
                  let nameEnd = line.range(of: ": "),
                  let dash = line.range(of: " - ", options: .backwards) else { continue }
            let name = String(line[..<nameEnd.lowerBound])
            let status = String(line[dash.upperBound...])
            if status.hasPrefix("✔") {
                states[name] = .connected
            } else if status.hasPrefix("!") {
                states[name] = .needsAuth
            } else if status.hasPrefix("✘") {
                states[name] = .failed(String(status.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return states
    }

    /// Une entrée par MCP requis non connecté.
    static func unavailable(required: [String], in states: [String: MCPServerState]) -> [String] {
        required.compactMap { name in
            switch states[name] {
            case .connected: return nil
            case .needsAuth: return "\(name) (needs-auth)"
            case .failed(let reason): return "\(name) (échec : \(reason))"
            case nil: return "\(name) (absent)"
            }
        }
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
