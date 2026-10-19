import Foundation

/// Mot « / » en cours sous le curseur : requête (texte après « / ») et position du « / » (en caractères).
public struct SlashTrigger: Equatable, Sendable {
    public let query: String
    public let start: Int

    public init(query: String, start: Int) {
        self.query = query
        self.start = start
    }
}

/// Brouillon après le choix d'une ligne du panneau, et position du curseur (en caractères).
public struct SlashReplacement: Equatable, Sendable {
    public let text: String
    public let cursor: Int

    public init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

/// Règles du web (`lib/promptInputTriggers.ts`, `slashCommandHelpers.ts`) restreintes à « / » :
/// `ACTIVE_TRIGGER_RE = /(^|\s)(\/)([^\s/@$#¥￥]*)$/` sur le texte avant le curseur, et `replaceActiveSlashToken`.
public enum SlashInput {
    /// Caractères qui terminent une requête (déclencheurs du web).
    static let stopCharacters: Set<Character> = ["/", "@", "$", "#", "¥", "￥"]

    /// Mot « / » qui finit `before` : « / » en début de texte ou après un blanc, suivi de caractères sans blanc ni
    /// déclencheur ; `nil` sinon (« / » collé à un mot, chemin, adresse).
    public static func activeTrigger(before text: String) -> SlashTrigger? {
        var query = ""
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "/" {
                guard previous == text.startIndex || text[text.index(before: previous)].isWhitespace else { return nil }
                return SlashTrigger(query: query, start: text.distance(from: text.startIndex, to: previous))
            }
            if character.isWhitespace || stopCharacters.contains(character) { return nil }
            query.insert(character, at: query.startIndex)
            index = previous
        }
        return nil
    }

    /// Remplace le mot en cours par `insertion` suivi d'une espace ; la fin du mot après le curseur n'est absorbée que
    /// si elle complète le nom choisi (`getActivePromptInputTokenTailLength`).
    public static func replace(before: String, after: String, with insertion: String) -> SlashReplacement? {
        guard let trigger = activeTrigger(before: before) else { return nil }
        let prefix = String(before.prefix(trigger.start))
        let suffix = String(after.dropFirst(tailLength(query: trigger.query, after: after, candidate: insertion)))
        return SlashReplacement(text: prefix + insertion + " " + suffix, cursor: prefix.count + insertion.count + 1)
    }

    static func tailLength(query: String, after: String, candidate: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let tail = after.prefix { !$0.isWhitespace && !stopCharacters.contains($0) }
        guard !tail.isEmpty else { return 0 }
        let name = candidate.trimmingCharacters(in: .whitespaces).drop { stopCharacters.contains($0) }
        guard name.lowercased().hasPrefix(query.lowercased()) else { return 0 }
        let expected = name.dropFirst(query.count)
        guard !expected.isEmpty else { return 0 }
        let comparable = min(tail.count, expected.count)
        return expected.lowercased().hasPrefix(tail.prefix(comparable).lowercased()) ? comparable : 0
    }
}
