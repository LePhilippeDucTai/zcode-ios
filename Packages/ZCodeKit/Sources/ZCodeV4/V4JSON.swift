import Foundation
import ZCodeWire

/// Trame ou valeur structurellement inutilisable (pas une simple valeur inconnue).
public enum V4DecodingError: Error, Equatable, Sendable {
    case missingField(String)
    case invalid(String)
}

/// Passerelle entre `JSONValue` (déjà décodé par la couche RPC) et les types `Codable` du protocole.
public enum V4JSON {
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue.decode(JSONEncoder().encode(value))
    }

    /// Entier exact (les nombres JSON sont des `Double`) ; `nil` si absent, fractionnaire ou non numérique.
    public static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(number)
    }
}
