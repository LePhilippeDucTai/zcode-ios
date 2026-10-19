import Foundation

extension String {
    /// Lignes sans leur fin (`\n`, `\r\n` ou `\r`) ; une fin de ligne finale ne produit pas de ligne vide.
    /// `\r\n` est **un seul** `Character` en Swift : `split(separator: "\n")` ne le coupe pas.
    var textLines: [String] {
        guard !isEmpty else { return [] }
        var lines = split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

extension String {
    /// Au-delà, une ligne affichée est coupée : un `Text` de plusieurs Mio fige la mise en page (JSON ou JS minifié).
    public static let maxDisplayedLineLength = 2_000

    /// La ligne, ou ses `maxDisplayedLineLength` premiers caractères suivis de « … (N caractères) ».
    public var clippedForDisplay: String {
        guard utf8.count > Self.maxDisplayedLineLength else { return self }
        let total = count
        guard total > Self.maxDisplayedLineLength else { return self }
        return String(prefix(Self.maxDisplayedLineLength)) + "… (\(total) caractères)"
    }
}

/// Aperçu d'un texte long dans une carte d'outil : ses premières lignes, le reste dépliable d'un toucher.
public struct LinePreview: Equatable, Sendable {
    /// Lignes affichées repliées dans une carte d'outil (sortie, commande, entrée).
    public static let cardLineCount = 12

    /// Le texte tel quel s'il ne cache rien ; sinon ses premières lignes jointes par `\n` (`\r\n` et `\r` normalisés).
    public let shown: String
    public let totalLineCount: Int
    public let hiddenLineCount: Int

    public init(shown: String, totalLineCount: Int, hiddenLineCount: Int) {
        self.shown = shown
        self.totalLineCount = totalLineCount
        self.hiddenLineCount = hiddenLineCount
    }

    /// Libellé du bouton qui déplie le texte : « Afficher les 34 lignes ».
    public var showAllLabel: String { "Afficher les \(totalLineCount) lignes" }
}

extension String {
    /// Les `maxLines` premières lignes (au sens de `textLines` : une fin de ligne finale ne compte pas) et le nombre de
    /// lignes cachées. À appeler sur un texte déjà borné en caractères : tout le texte est découpé.
    public func linePreview(maxLines: Int = LinePreview.cardLineCount) -> LinePreview {
        let lines = textLines
        guard lines.count > maxLines else {
            return LinePreview(shown: self, totalLineCount: lines.count, hiddenLineCount: 0)
        }
        return LinePreview(shown: lines.prefix(maxLines).joined(separator: "\n"), totalLineCount: lines.count,
                           hiddenLineCount: lines.count - maxLines)
    }
}
