import Foundation

/// Texte Markdown dont chaque formule en ligne est remplacée par un marqueur (caractère d'usage privé U+E000 + rang) :
/// le Markdown en ligne s'analyse une seule fois — gras, italique ou lien qui entourent une formule compris — puis la
/// chaîne attribuée est recoupée aux marqueurs (`pieces(of:)`).
public struct MathMarkdown: Equatable, Sendable {
    public let markdown: String
    public let formulas: [InlineFormula]

    static let firstMarker: UInt32 = 0xE000
    static let lastMarker: UInt32 = 0xF8FF

    public enum Piece: Equatable, Sendable {
        case text(AttributedString)
        /// Rang dans `formulas`.
        case formula(Int)
    }

    public static func prepare(_ text: String) -> MathMarkdown {
        // Un texte qui contient déjà un caractère de la plage ne reçoit aucune formule : marqueurs ambigus.
        guard text.contains("$"),
              !text.unicodeScalars.contains(where: { (firstMarker...lastMarker).contains($0.value) }) else {
            return MathMarkdown(markdown: text, formulas: [])
        }
        var markdown = ""
        var formulas: [InlineFormula] = []
        for segment in MathText.segments(text) {
            switch segment {
            case .text(let piece):
                markdown += piece
            case .formula(let formula):
                let value = firstMarker + UInt32(formulas.count)
                if value <= lastMarker, let marker = Unicode.Scalar(value) {
                    markdown.unicodeScalars.append(marker)
                    formulas.append(formula)
                } else {
                    markdown += formula.raw                  // au-delà de 6 400 formules : source brute
                }
            }
        }
        return MathMarkdown(markdown: markdown, formulas: formulas)
    }

    /// La chaîne attribuée (Markdown de `markdown` analysé, ou texte brut) recoupée en texte et formules.
    public func pieces(of attributed: AttributedString) -> [Piece] {
        guard !formulas.isEmpty else { return [.text(attributed)] }
        var pieces: [Piece] = []
        var start = attributed.startIndex
        var index = attributed.startIndex
        while index < attributed.endIndex {
            let next = attributed.characters.index(after: index)
            if let rank = rank(of: attributed.characters[index]) {
                if start < index { pieces.append(.text(AttributedString(attributed[start..<index]))) }
                pieces.append(.formula(rank))
                start = next
            }
            index = next
        }
        if start < attributed.endIndex { pieces.append(.text(AttributedString(attributed[start...]))) }
        return pieces
    }

    private func rank(of character: Character) -> Int? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              scalar.value >= Self.firstMarker, scalar.value - Self.firstMarker < UInt32(formulas.count) else { return nil }
        return Int(scalar.value - Self.firstMarker)
    }
}
