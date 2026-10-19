import Foundation
import ZCodeWire

enum ProbeScriptError: Error, Equatable {
    case missingVariables([String])
}

/// Script de sonde : une suite d'étapes exécutées sur une seule connexion.
struct ProbeScript: Decodable, Equatable {
    var steps: [ProbeStep]

    static func load(from url: URL, environment: [String: String]) throws -> ProbeScript {
        try parse(String(contentsOf: url, encoding: .utf8), environment: environment)
    }

    /// Remplace chaque `${NOM}` par la variable d'environnement `NOM`, puis décode le JSON.
    static func parse(_ text: String, environment: [String: String]) throws -> ProbeScript {
        var missing: [String] = []
        let substituted = text.replacing(/\$\{([A-Z_][A-Z0-9_]*)\}/) { match in
            let name = String(match.1)
            if let value = environment[name] {
                return value
            }
            missing.append(name)
            return ""
        }
        guard missing.isEmpty else {
            throw ProbeScriptError.missingVariables(missing)
        }
        return try JSONDecoder().decode(ProbeScript.self, from: Data(substituted.utf8))
    }
}

enum ProbeStep: Decodable, Equatable {
    /// Appel de méthode ; `args` est le tableau des arguments (`[]` sans paramètre).
    case call(channel: String, method: String, args: [JSONValue])
    /// Écoute d'événement ; `arg` est transmis tel quel (événements `onDynamicXxx`).
    case listen(channel: String, event: String, arg: JSONValue?)
    /// Pause, pour laisser arriver les événements.
    case wait(seconds: Double)

    private enum CodingKeys: String, CodingKey {
        case call, method, args, listen, event, arg, wait
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let channel = try container.decodeIfPresent(String.self, forKey: .call) {
            self = .call(
                channel: channel,
                method: try container.decode(String.self, forKey: .method),
                args: try container.decodeIfPresent([JSONValue].self, forKey: .args) ?? []
            )
        } else if let channel = try container.decodeIfPresent(String.self, forKey: .listen) {
            self = .listen(
                channel: channel,
                event: try container.decode(String.self, forKey: .event),
                arg: try container.decodeIfPresent(JSONValue.self, forKey: .arg)
            )
        } else if let seconds = try container.decodeIfPresent(Double.self, forKey: .wait) {
            self = .wait(seconds: seconds)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "étape inconnue (attendu : call, listen ou wait)"
            ))
        }
    }
}
