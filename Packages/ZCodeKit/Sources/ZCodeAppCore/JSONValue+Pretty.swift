import Foundation
import ZCodeWire

extension JSONValue {
    /// JSON indenté, clés triées : contenu des cartes « non pris en charge » et des arguments d'outils.
    public var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return String(describing: self)
        }
        return text
    }
}
