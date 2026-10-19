import Foundation

/// Jetons insérés par le panneau « / » (`$skill`, `@sous-agent`) et le texte qui part à leur place. À l'envoi, chaque
/// jeton **encore présent tel quel**, en mot entier (entre deux blancs ou bords du texte), est remplacé ; un jeton
/// modifié, effacé ou tapé à la main part tel quel. Vidée à l'envoi et à la suppression du brouillon.
public struct SlashTokens: Equatable, Sendable {
    public private(set) var replacements: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { replacements.isEmpty }

    public mutating func record(_ token: String, sendAs: String) {
        replacements[token] = sendAs
    }

    public mutating func removeAll() {
        replacements = [:]
    }

    public func expand(_ text: String) -> String {
        // Les jetons les plus longs d'abord : ordre déterministe (deux jetons ne se chevauchent pas en mot entier).
        replacements.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.reduce(text) { result, token in
            Self.replacingWholeWords(token, with: replacements[token] ?? token, in: result)
        }
    }

    static func replacingWholeWords(_ token: String, with replacement: String, in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in text.ranges(of: token) where range.lowerBound >= cursor {
            let startsWord = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace
            let endsWord = range.upperBound == text.endIndex || text[range.upperBound].isWhitespace
            guard startsWord, endsWord else { continue }
            result += text[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
