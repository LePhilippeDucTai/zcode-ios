import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    /// Paragraphe (Markdown en ligne : gras, italique, code, liens), rendu par `AttributedString(markdown:)`.
    case text(String)
    case heading(level: Int, text: String)
    /// Élément de liste : `marker` = « • », « 1. », « ☐ » ou « ☑ » ; `depth` = niveau d'imbrication (0 en tête).
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case rule
    case code(language: String?, code: String)
    /// Formule en bloc : `$$` … `$$` (règle de micromark `mathFlow`) ou bloc ```` ```math ```` (rendu par KaTeX en mode
    /// bloc sur le web) ; source LaTeX sans délimiteurs, jamais vide.
    case math(String)
    /// Tableau GFM : la première ligne est l'en-tête ; la ligne de séparation `|---|` est retirée.
    case table([[String]])
}

/// Découpe un texte Markdown en blocs ; le Markdown en ligne de chaque bloc reste à `AttributedString`.
public enum MarkdownBlocks {
    /// Un bloc de code non refermé (réponse en cours de streaming) garde la suite comme code.
    public static func split(_ markdown: String) -> [MarkdownBlock] {
        var parser = BlockParser()
        for line in markdown.textLines {
            parser.consume(line)
        }
        return parser.finish()
    }
}

private struct Fence {
    let marker: Character
    let length: Int
    let language: String?
    var lines: [String] = []
}

/// Lecture ligne à ligne : paragraphe, citation et tableau s'accumulent jusqu'à une ligne d'un autre genre.
private struct BlockParser {
    private var blocks: [MarkdownBlock] = []
    private var paragraph: [String] = []
    private var quote: [String] = []
    private var table: [[String]] = []
    private var fence: Fence?
    private var mathFence: (length: Int, lines: [String])?

    mutating func consume(_ line: String) {
        if var open = mathFence {
            if MathText.closesMathFence(line.trimmingCharacters(in: .whitespaces), length: open.length) {
                appendMath(open.lines)
                mathFence = nil
            } else {
                open.lines.append(line)
                mathFence = open
            }
            return
        }
        if var open = fence {
            if Self.closes(line, open) {
                appendFence(open)
                fence = nil
            } else {
                open.lines.append(line)
                fence = open
            }
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        if indent < 4, let length = MathText.mathFenceOpening(trimmed) {
            flushAll()
            mathFence = (length, [])
        } else if indent < 4, let opening = Self.fenceOpening(trimmed) {
            flushAll()
            fence = opening
        } else if trimmed.isEmpty {
            flushAll()
        } else if trimmed.hasPrefix(">") {
            flushParagraph()
            flushTable()
            var content = trimmed.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            quote.append(String(content))
        } else if trimmed.hasPrefix("|") {
            flushParagraph()
            flushQuote()
            let cells = Self.cells(trimmed)
            if !cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) { table.append(cells) }
        } else if Self.isRule(trimmed) {
            flushAll()
            blocks.append(.rule)
        } else if let heading = Self.heading(trimmed) {
            flushAll()
            blocks.append(heading)
        } else if let item = Self.listItem(trimmed, indent: indent) {
            flushAll()
            blocks.append(item)
        } else if !quote.isEmpty {
            quote.append(trimmed)                                     // continuation paresseuse d'une citation
        } else if paragraph.isEmpty, indent > 0, case .listItem(let marker, let depth, let text)? = blocks.last {
            blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
        } else {
            flushTable()
            paragraph.append(trimmed)
        }
    }

    mutating func finish() -> [MarkdownBlock] {
        if let open = mathFence {
            appendMath(open.lines)
            mathFence = nil
        }
        if let open = fence {
            appendFence(open)
            fence = nil
        }
        flushAll()
        return blocks
    }

    /// Un bloc ```` ```math ```` est une formule en bloc, comme sur le web (`rehype-katex`, `language-math`).
    private mutating func appendFence(_ open: Fence) {
        let code = open.lines.joined(separator: "\n")
        if open.language == "math" {
            appendMath(open.lines)
        } else {
            blocks.append(.code(language: open.language, code: code))
        }
    }

    private mutating func appendMath(_ lines: [String]) {
        let latex = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !latex.isEmpty { blocks.append(.math(latex)) }
    }

    private mutating func flushAll() {
        flushParagraph()
        flushQuote()
        flushTable()
    }

    private mutating func flushParagraph() {
        let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { blocks.append(.text(text)) }
        paragraph = []
    }

    private mutating func flushQuote() {
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
        quote = []
    }

    private mutating func flushTable() {
        if !table.isEmpty { blocks.append(.table(table)) }
        table = []
    }

    /// ```` ``` ```` ou `~~~` (trois au moins) ; le langage est le premier mot de l'info.
    private static func fenceOpening(_ trimmed: String) -> Fence? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, length: length, language: info.split(separator: " ").first.map(String.init))
    }

    /// Même caractère, au moins aussi long que l'ouverture, rien d'autre sur la ligne.
    private static func closes(_ line: String, _ fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.marker }
    }

    /// `---`, `***` ou `___` (espaces permis), trois au moins.
    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard let first = compact.first, "-*_".contains(first), compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard let match = trimmed.wholeMatch(of: /(#{1,6})[ \t]+(.+)/) else { return nil }
        let text = String(match.2).replacing(/[ \t]+#+[ \t]*$/, with: "").trimmingCharacters(in: .whitespaces)
        return .heading(level: match.1.count, text: text)
    }

    private static func listItem(_ trimmed: String, indent: Int) -> MarkdownBlock? {
        let depth = min(indent / 2, 6)
        if let match = trimmed.wholeMatch(of: /[-*+][ \t]+(.+)/) {
            let text = String(match.1)
            if text.hasPrefix("[ ] ") { return .listItem(marker: "☐", depth: depth, text: String(text.dropFirst(4))) }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                return .listItem(marker: "☑", depth: depth, text: String(text.dropFirst(4)))
            }
            return .listItem(marker: "•", depth: depth, text: text)
        }
        if let match = trimmed.wholeMatch(of: /(\d{1,9}[.)])[ \t]+(.+)/) {
            return .listItem(marker: String(match.1), depth: depth, text: String(match.2))
        }
        return nil
    }

    /// `| a | b |` → `["a", "b"]`.
    private static func cells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
