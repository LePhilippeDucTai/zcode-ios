import Foundation

/// Valeur du sérialiseur RPC de ZCode (`packages/rpc/src/serialization.ts`) :
/// une étiquette d'un octet suivie des données.
public enum RPCValue: Sendable, Hashable {
    /// Étiquette 0.
    case undefined
    /// Étiquette 1 : longueur VQL + UTF-8.
    case string(String)
    /// Étiquette 2 : `Uint8Array`.
    case buffer(Data)
    /// Étiquette 3 : `VSBuffer`.
    case vsBuffer(Data)
    /// Étiquette 4 : nombre d'éléments VQL + éléments sérialisés.
    case array([RPCValue])
    /// Étiquette 5 : repli JSON (objets, booléens, `null`, flottants, entiers hors int32).
    case json(JSONValue)
    /// Étiquette 6 : entier 32 bits encodé en VQL.
    case int(Int32)
}

extension RPCValue {
    /// Répartit une valeur JSON comme `serialize()` côté JavaScript : chaînes, entiers 32 bits et
    /// tableaux ont leur étiquette dédiée ; tout le reste passe par le repli JSON.
    public init(_ json: JSONValue) {
        switch json {
        case .string(let value):
            self = .string(value)
        case .number(let value):
            if let integer = Int32(exactly: value) {
                self = .int(integer)
            } else {
                self = .json(json)
            }
        case .array(let items):
            self = .array(items.map(RPCValue.init))
        case .null, .bool, .object:
            self = .json(json)
        }
    }

    /// Vue JSON de la valeur : `undefined` → `nil` (`null` dans un tableau), octets → chaîne base64.
    public var jsonValue: JSONValue? {
        switch self {
        case .undefined: nil
        case .string(let value): .string(value)
        case .buffer(let bytes), .vsBuffer(let bytes): .string(bytes.base64EncodedString())
        case .array(let items): .array(items.map { $0.jsonValue ?? .null })
        case .json(let value): value
        case .int(let value): .number(Double(value))
        }
    }
}
