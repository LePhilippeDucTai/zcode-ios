import SwiftUI

/// Texte avant et après le curseur du composeur.
enum ComposerCursor {
    /// Sans sélection connue, le curseur est en fin de brouillon (règle de la spec) ; une plage sélectionnée (non vide)
    /// n'ouvre pas le panneau : `nil`. L'index de SwiftUI peut dater d'une version plus ancienne du texte : il est
    /// ramené dans le texte courant.
    static func split(_ text: String, _ selection: TextSelection?) -> (before: String, after: String)? {
        guard let selection else { return (text, "") }
        guard case .selection(let range) = selection.indices, range.isEmpty else { return nil }
        // Un index plus loin que la fin du texte courant (brouillon raccourci depuis) fait échouer `utf16Offset(in:)` :
        // la comparaison, elle, ne plante pas, on borne donc avant de mesurer.
        let bounded = min(range.lowerBound, text.endIndex)
        let offset = bounded.utf16Offset(in: text)
        let index = String.Index(utf16Offset: offset, in: text)
        return (String(text[..<index]), String(text[index...]))
    }
}
