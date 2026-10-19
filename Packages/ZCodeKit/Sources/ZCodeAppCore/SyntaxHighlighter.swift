import Foundation

/// Genre d'un jeton de code coloré.
public enum SyntaxTokenKind: Equatable, Sendable {
    case keyword, string, comment, number, type, plain
}

/// Morceau de code et son genre ; mis bout à bout, les jetons redonnent exactement le code.
public struct SyntaxToken: Equatable, Sendable {
    public let kind: SyntaxTokenKind
    public let text: String

    public init(_ kind: SyntaxTokenKind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Langages colorés ; tout autre bloc reste en texte brut.
public enum SyntaxLanguage: Sendable {
    case swift, typescript, python, shell, json, rust, go

    /// Langage d'un bloc Markdown (« ```TSX » → TypeScript), casse ignorée ; `nil` si inconnu ou absent.
    public init?(fenceName: String?) {
        switch fenceName?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift": self = .swift
        case "ts", "tsx", "typescript", "js", "jsx", "javascript", "mjs", "cjs": self = .typescript
        case "py", "python", "python3": self = .python
        case "sh", "bash", "zsh", "shell": self = .shell
        case "json": self = .json
        case "rs", "rust": self = .rust
        case "go", "golang": self = .go
        default: return nil
        }
    }
}

/// Coloration syntaxique sans dépendance : découpage lexical simple (mots-clés, chaînes, commentaires, nombres, types)
/// suffisant pour lire du code sur un téléphone, pas une analyse du langage.
public enum SyntaxHighlighter {
    /// Au-delà, texte brut : la fluidité de la conversation passe avant la couleur.
    public static let maxLength = 20_000

    public static func tokens(_ code: String, language: String?) -> [SyntaxToken] {
        guard !code.isEmpty else { return [] }
        guard code.count <= maxLength, let language = SyntaxLanguage(fenceName: language) else {
            return [SyntaxToken(.plain, code)]
        }
        var lexer = Lexer(chars: Array(code), grammar: Grammar(language))
        return lexer.run()
    }
}

/// Règles lexicales d'un langage.
private struct Grammar {
    var keywords: Set<String> = []
    var lineComment: [Character]?
    /// `#` ne commente qu'en début de ligne ou après un blanc (shell : `a#b` est un mot).
    var lineCommentNeedsBlank = false
    var blockComment: (open: [Character], close: [Character])?
    /// Délimiteurs de chaîne ; une chaîne non fermée s'arrête en fin de ligne, sauf délimiteur multiligne.
    var quotes: Set<Character> = []
    var multilineQuotes: Set<Character> = []
    /// Sans échappement par `\` (shell `'…'`, Go `` `…` ``).
    var rawQuotes: Set<Character> = []
    /// `"""` (et `'''` si `'` est un délimiteur) : chaîne multiligne.
    var tripleQuotes = false
    /// Mot commençant par une majuscule = type.
    var capitalizedTypes = true

    init(_ language: SyntaxLanguage) {
        let slashes: [Character] = ["/", "/"]
        let block: (open: [Character], close: [Character]) = (["/", "*"], ["*", "/"])
        switch language {
        case .swift:
            keywords = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                        "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout",
                        "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "override", "private",
                        "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct",
                        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak",
                        "where", "while"]
            lineComment = slashes
            blockComment = block
            quotes = ["\""]
            tripleQuotes = true
        case .typescript:
            keywords = ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "declare",
                        "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from",
                        "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
                        "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return",
                        "satisfies", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
                        "undefined", "var", "void", "while", "yield"]
            lineComment = slashes
            blockComment = block
            quotes = ["\"", "'", "`"]
            multilineQuotes = ["`"]
        case .python:
            keywords = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class",
                        "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                        "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
                        "self", "try", "while", "with", "yield"]
            lineComment = ["#"]
            quotes = ["\"", "'"]
            tripleQuotes = true
        case .shell:
            keywords = ["alias", "break", "case", "continue", "do", "done", "elif", "else", "esac", "exit", "export",
                        "fi", "for", "function", "if", "in", "local", "readonly", "return", "select", "set", "source",
                        "then", "time", "unset", "until", "while"]
            lineComment = ["#"]
            lineCommentNeedsBlank = true
            quotes = ["\"", "'"]
            rawQuotes = ["'"]
            capitalizedTypes = false
        case .json:
            keywords = ["true", "false", "null"]
            quotes = ["\""]
            capitalizedTypes = false
        case .rust:
            keywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                        "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                        "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                        "use", "where", "while"]
            lineComment = slashes
            blockComment = block
            quotes = ["\""]                                     // `'` : caractère ou durée de vie, laissé brut
        case .go:
            keywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                        "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil",
                        "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
            lineComment = slashes
            blockComment = block
            quotes = ["\"", "'", "`"]
            multilineQuotes = ["`"]
            rawQuotes = ["`"]
        }
    }
}

/// Lecture caractère par caractère ; le texte entre deux jetons reconnus devient un jeton `.plain`.
private struct Lexer {
    let chars: [Character]
    let grammar: Grammar
    private var index = 0
    private var tokens: [SyntaxToken] = []

    init(chars: [Character], grammar: Grammar) {
        self.chars = chars
        self.grammar = grammar
    }

    mutating func run() -> [SyntaxToken] {
        var plainStart = 0
        while index < chars.count {
            let start = index
            guard let kind = scan() else { continue }       // `scan` a avancé : ces caractères restent bruts
            if plainStart < start { tokens.append(SyntaxToken(.plain, String(chars[plainStart..<start]))) }
            tokens.append(SyntaxToken(kind, String(chars[start..<index])))
            plainStart = index
        }
        if plainStart < chars.count { tokens.append(SyntaxToken(.plain, String(chars[plainStart...]))) }
        return tokens
    }

    /// Lit un élément à partir de `index` (au moins un caractère) ; son genre, ou `nil` pour du texte brut.
    private mutating func scan() -> SyntaxTokenKind? {
        let char = chars[index]
        if let marker = grammar.lineComment, matches(marker),
           !grammar.lineCommentNeedsBlank || index == 0 || chars[index - 1].isWhitespace {
            while index < chars.count, !chars[index].isNewline { index += 1 }
            return .comment
        }
        if let block = grammar.blockComment, matches(block.open) {
            index += block.open.count
            while index < chars.count, !matches(block.close) { index += 1 }
            index = min(chars.count, index + block.close.count)
            return .comment
        }
        if grammar.quotes.contains(char) {
            let triple = [Character](repeating: char, count: 3)
            if grammar.tripleQuotes, matches(triple) {
                index += 3
                while index < chars.count, !matches(triple) {
                    if chars[index] == "\\" { index += 1 }
                    index += 1
                }
                index = min(chars.count, index + 3)
                return .string
            }
            let raw = grammar.rawQuotes.contains(char)
            let multiline = grammar.multilineQuotes.contains(char)
            index += 1
            while index < chars.count, chars[index] != char {
                if !multiline, chars[index].isNewline { break }
                if !raw, chars[index] == "\\" { index += 1 }
                index += 1
            }
            if index < chars.count, chars[index] == char { index += 1 }
            index = min(chars.count, index)
            return .string
        }
        if char.isASCII, char.isNumber {
            while index < chars.count, chars[index].isASCII,
                  chars[index].isLetter || chars[index].isNumber || chars[index] == "." || chars[index] == "_" {
                index += 1
            }
            return .number
        }
        if char.isLetter || char == "_" {
            let start = index
            while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
            let word = String(chars[start..<index])
            if grammar.keywords.contains(word) { return .keyword }
            if grammar.capitalizedTypes, word.first?.isUppercase == true { return .type }
            return nil
        }
        index += 1
        return nil
    }

    private func matches(_ marker: [Character]) -> Bool {
        guard index + marker.count <= chars.count else { return false }
        for (offset, char) in marker.enumerated() where chars[index + offset] != char { return false }
        return true
    }
}
