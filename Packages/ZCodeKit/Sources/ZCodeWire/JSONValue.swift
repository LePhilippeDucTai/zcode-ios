import Foundation

/// Valeur JSON arbitraire, telle qu'échangée dans les corps `Object` du protocole RPC.
///
/// Les nombres sont des `Double`, comme en JavaScript : les entiers jusqu'à 2^53 restent exacts,
/// ce qui couvre les horodatages en millisecondes du serveur.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Valeur JSON non reconnue")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// JSON compact, clés triées, `/` non échappé (équivalent de `JSON.stringify` à l'ordre des clés près).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public var stringValue: String? {
        switch self { case .string(let value): value; default: nil }
    }

    public var numberValue: Double? {
        switch self { case .number(let value): value; default: nil }
    }

    public var boolValue: Bool? {
        switch self { case .bool(let value): value; default: nil }
    }

    public var arrayValue: [JSONValue]? {
        switch self { case .array(let value): value; default: nil }
    }

    public var objectValue: [String: JSONValue]? {
        switch self { case .object(let value): value; default: nil }
    }
}
