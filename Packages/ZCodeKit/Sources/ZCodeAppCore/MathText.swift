import Foundation

/// Formule en ligne trouvée dans un texte : `latex` part à KaTeX ; `raw` (délimiteurs compris) s'affiche tant que
/// l'image n'est pas prête.
public struct InlineFormula: Hashable, Sendable {
    public let latex: String
    public let raw: String

    public init(latex: String, raw: String) {
        self.latex = latex
        self.raw = raw
    }
}

public enum MathSegment: Hashable, Sendable {
    case text(String)
    case formula(InlineFormula)
}

/// Morceau de la bulle de l'utilisateur : texte où chercher les formules en ligne, bloc de code clôturé laissé tel
/// quel, formule en bloc `$$`.
public enum MessageMathPart: Hashable, Sendable {
    case text(String)
    case code(String)
    case block(String)
}

/// Reconnaissance des formules LaTeX, règles de ZCode Web 3.15.1 portées telles quelles : `message.tsx` pour `$…$`
/// (`isLikelySingleDollarMath` et voisines), `micromark-extension-math` 3.1.0 pour `$$…$$`.
public enum MathText {
    // MARK: - Règles du web pour `$…$` (message.tsx)

    /// `isEscapedMarkdownCharacter` : nombre impair de `\` juste avant.
    static func isEscaped(_ chars: [Character], _ index: Int) -> Bool {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, chars[cursor] == "\\" {
            count += 1
            cursor -= 1
        }
        return count % 2 == 1
    }

    /// `isSingleDollarDelimiter` : `$` seul (ni `$` avant ni après), non échappé.
    static func isSingleDollarDelimiter(_ chars: [Character], _ index: Int) -> Bool {
        chars[index] == "$"
            && (index == 0 || chars[index - 1] != "$")
            && (index + 1 >= chars.count || chars[index + 1] != "$")
            && !isEscaped(chars, index)
    }

    /// `findClosingSingleDollarDelimiter`.
    static func closingSingleDollar(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            if isSingleDollarDelimiter(chars, index) { return index }
            index += 1
        }
        return nil
    }

    /// `likelyMathSyntaxPattern` = `/[\\{}^_=+\-*/<>|()[\]∇∂∫∑√∞≈≠≤≥±×÷πΠα-ωΑ-Ω]/u`.
    private static let mathSyntaxScalars: Set<Unicode.Scalar> = Set("\\{}^_=+-*/<>|()[]∇∂∫∑√∞≈≠≤≥±×÷πΠ".unicodeScalars)

    static func isLikelyMathSyntax(_ scalar: Unicode.Scalar) -> Bool {
        mathSyntaxScalars.contains(scalar) || (0x3B1...0x3C9).contains(scalar.value) || (0x391...0x3A9).contains(scalar.value)
    }

    /// `isLikelySingleDollarMath`. `texCommandPattern` = `/\\[A-Za-z]+/` ; `simpleMathIdentifierPattern` =
    /// `/^(?:[A-Za-z]|[a-z][A-Za-z0-9]{1,2}|\d+(?:\.\d+)?)$/` (`\d` du JS = chiffres ASCII).
    public static func isLikelySingleDollarMath(_ content: String) -> Bool {
        guard !content.isEmpty, content == content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return false }
        if content.contains(#/\\[A-Za-z]+/#) || content.unicodeScalars.contains(where: isLikelyMathSyntax) { return true }
        if !content.contains(where: \.isWhitespace),
           content.wholeMatch(of: #/[A-Za-z]|[a-z][A-Za-z0-9]{1,2}|[0-9]+(?:\.[0-9]+)?/#) != nil {
            return true
        }
        return false
    }

    /// `isLikelyCompactCurrencyRangeText` : `compactCurrencyRangePrefixPattern` =
    /// `/^(?:\d[\d,]*(?:\.\d+)?|\.\d+)[+\-*/]$/` sur le contenu, `compactCurrencyAmountStartPattern` = `/^(?:\d|\.\d)/`
    /// sur la suite du texte.
    static func isLikelyCompactCurrencyRange(_ chars: [Character], closing: Int, content: String) -> Bool {
        guard content.wholeMatch(of: #/(?:[0-9][0-9,]*(?:\.[0-9]+)?|\.[0-9]+)[+\-*\/]/#) != nil else { return false }
        return String(chars[(closing + 1)...]).prefixMatch(of: #/[0-9]|\.[0-9]/#) != nil
    }

    /// Sort d'un `$` dans `normalizeSingleDollarMathInText` : laissé, échappé en `\$`, ou formule jusqu'à `closing`.
    enum SingleDollar {
        case literal, escaped
        case formula(closing: Int)
    }

    static func singleDollar(_ chars: [Character], at index: Int) -> SingleDollar {
        guard isSingleDollarDelimiter(chars, index), let closing = closingSingleDollar(chars, from: index + 1) else {
            return .literal
        }
        let content = String(chars[(index + 1)..<closing])
        if isLikelyCompactCurrencyRange(chars, closing: closing, content: content) { return .escaped }
        return isLikelySingleDollarMath(content) ? .formula(closing: closing) : .escaped
    }

    /// `normalizeSingleDollarMathInText` (oracle des vecteurs du web ; l'app n'affiche jamais ce texte).
    public static func normalizeSingleDollarMathInText(_ text: String) -> String {
        guard text.contains("$") else { return text }
        let chars = Array(text)
        var output = ""
        var index = 0
        while index < chars.count {
            switch singleDollar(chars, at: index) {
            case .literal:
                output.append(chars[index])
                index += 1
            case .escaped:
                output += "\\$"
                index += 1
            case .formula(let closing):
                output += String(chars[index...closing])
                index = closing + 1
            }
        }
        return output
    }

    /// `normalizeSingleDollarMathOutsideInlineCode`.
    public static func normalizeSingleDollarMathOutsideInlineCode(_ line: String) -> String {
        inlineCodePieces(line).map { $0.isCode ? $0.text : normalizeSingleDollarMathInText($0.text) }.joined()
    }

    /// Découpage de `normalizeSingleDollarMathOutsideInlineCode` : code en ligne (même suite d'accents graves pour
    /// fermer, cherchée comme `indexOf`) ; un code non refermé rend la suite, accent grave compris, au texte.
    static func inlineCodePieces(_ line: String) -> [(text: String, isCode: Bool)] {
        let chars = Array(line)
        var pieces: [(text: String, isCode: Bool)] = []
        var cursor = 0
        while cursor < chars.count {
            guard let codeStart = chars[cursor...].firstIndex(of: "`") else {
                pieces.append((String(chars[cursor...]), false))
                break
            }
            pieces.append((String(chars[cursor..<codeStart]), false))
            var fenceEnd = codeStart + 1
            while fenceEnd < chars.count, chars[fenceEnd] == "`" { fenceEnd += 1 }
            let marker = Array(chars[codeStart..<fenceEnd])
            guard let codeEnd = firstIndex(of: marker, in: chars, from: fenceEnd) else {
                pieces.append((String(chars[codeStart...]), false))
                break
            }
            pieces.append((String(chars[codeStart..<(codeEnd + marker.count)]), true))
            cursor = codeEnd + marker.count
        }
        return pieces
    }

    private static func firstIndex(of needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        var index = start
        while index + needle.count <= chars.count {
            if Array(chars[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Blocs `$$` (micromark `mathFlow`)

    /// Ouverture : n ≥ 2 `$` en tête de ligne (retrait < 4, vérifié par l'appelant), puis une « méta » ignorée qui ne
    /// contient aucun `$` — `$$x$$` sur une seule ligne n'ouvre donc pas de bloc. Rend n.
    static func mathFenceOpening(_ trimmed: String) -> Int? {
        let length = trimmed.prefix { $0 == "$" }.count
        guard length >= 2, !trimmed.dropFirst(length).contains("$") else { return nil }
        return length
    }

    /// Fermeture : au moins autant de `$` que l'ouverture, rien d'autre sur la ligne.
    static func closesMathFence(_ trimmed: String, length: Int) -> Bool {
        trimmed.count >= length && trimmed.allSatisfy { $0 == "$" }
    }

    /// `getMarkdownFence` du web : `markdownFencePattern` = `/^(?: {0,3})(`{3,}|~{3,})/`.
    static func markdownFence(_ line: String) -> (marker: Character, length: Int)? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let rest = line.dropFirst(spaces)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    /// Bulle de l'utilisateur (texte brut) : blocs de code clôturés comme `normalizeMessageSingleDollarMath` (même
    /// marque, au moins aussi longue, pour fermer), formules en bloc `$$` comme `MarkdownBlocks`.
    /// Sans bloc de code ni formule en bloc, rend `[.text(text)]` : le texte entier, ni rogné ni découpé.
    /// Coupe sur le seul scalaire `\n`, comme `segments` : un `\r` reste en fin de ligne, donc un bloc de code garde
    /// ses `\r\n` à l'octet près ; les clôtures se reconnaissent sans ce `\r`.
    public static func messageParts(_ text: String) -> [MessageMathPart] {
        enum State {
            case text
            case code(marker: Character, length: Int)
            case math(length: Int)
        }
        var parts: [MessageMathPart] = []
        var lines: [String] = []
        var state = State.text
        func close(_ make: (String) -> MessageMathPart?) {
            if let part = make(lines.joined(separator: "\n")) { parts.append(part) }
            lines = []
        }
        let textPart: (String) -> MessageMathPart? = { chunk in
            let trimmed = chunk.trimmingCharacters(in: .newlines)
            return trimmed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(trimmed)
        }
        let blockPart: (String) -> MessageMathPart? = { latex in
            let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .block(trimmed)
        }
        let codePart: (String) -> MessageMathPart? = { .code($0) }
        for scalars in text.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = String(String.UnicodeScalarView(scalars))
            // Ligne sans son `\r` final : sert à reconnaître les clôtures, et au contenu d'une formule en bloc.
            let bare = line.hasSuffix("\r") ? String(line.dropLast()) : line
            switch state {
            case .text:
                if leadingIndent(bare) < 4, let length = mathFenceOpening(bare.trimmingCharacters(in: .whitespaces)) {
                    close(textPart)
                    state = .math(length: length)
                } else if let fence = markdownFence(bare) {
                    close(textPart)
                    lines = [line]
                    state = .code(marker: fence.marker, length: fence.length)
                } else {
                    lines.append(line)
                }
            case .code(let marker, let length):
                if let fence = markdownFence(bare), fence.marker == marker, fence.length >= length {
                    // Le `\r` de la clôture appartient à la fin de ligne qui suit le bloc, comme le `\n` retiré.
                    lines.append(bare)
                    close(codePart)
                    state = .text
                } else {
                    lines.append(line)
                }
            case .math(let length):
                if closesMathFence(bare.trimmingCharacters(in: .whitespaces), length: length) {
                    close(blockPart)
                    state = .text
                } else {
                    lines.append(bare)
                }
            }
        }
        switch state {
        case .text: close(textPart)
        case .code: close(codePart)
        case .math: close(blockPart)
        }
        // Ni bloc `$$` ni bloc de code : une seule phrase, texte d'origine intact (aucun découpage à faire).
        let hasBlock = parts.contains {
            if case .text = $0 { return false }
            return true
        }
        return hasBlock ? parts : [.text(text)]
    }

    // MARK: - Segments texte / formule

    /// Segments d'un texte (paragraphe, titre, cellule, bulle) : chaque ligne à part (règle du web : coupe sur le seul `\n` de l'unité UTF-16, un `\r` reste en fin de ligne), code en ligne
    /// intact, `$…$` selon les règles du web, `$$…$$` selon micromark ; le texte garde ses caractères tels quels.
    public static func segments(_ text: String) -> [MathSegment] {
        guard text.contains("$") else { return text.isEmpty ? [] : [.text(text)] }
        var result: [MathSegment] = []
        for (number, line) in text.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).enumerated() {
            if number > 0 { append(.text("\n"), to: &result) }
            for segment in lineSegments(String(String.UnicodeScalarView(line))) { append(segment, to: &result) }
        }
        return result
    }

    static func lineSegments(_ line: String) -> [MathSegment] {
        var segments: [MathSegment] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { segments.append(.text(buffer)) }
            buffer = ""
        }
        for piece in inlineCodePieces(line) {
            guard !piece.isCode, piece.text.contains("$") else {
                buffer += piece.text
                continue
            }
            let chars = Array(piece.text)
            var index = 0
            while index < chars.count {
                guard chars[index] == "$", !isEscaped(chars, index) else {
                    buffer.append(chars[index])
                    index += 1
                    continue
                }
                let run = chars[index...].prefix { $0 == "$" }.count
                if run >= 2 {
                    if let found = doubleDollar(chars, at: index, run: run) {
                        flush()
                        segments.append(.formula(InlineFormula(latex: found.latex, raw: String(chars[index..<found.end]))))
                        index = found.end
                    } else {
                        buffer += String(repeating: "$", count: run)
                        index += run
                    }
                    continue
                }
                if case .formula(let closing) = singleDollar(chars, at: index) {
                    flush()
                    segments.append(.formula(InlineFormula(latex: String(chars[(index + 1)..<closing]),
                                                           raw: String(chars[index...closing]))))
                    index = closing + 1
                } else {
                    buffer.append("$")
                    index += 1
                }
            }
        }
        flush()
        return segments
    }

    /// micromark `mathText` à n ≥ 2 `$` : fermé par exactement n `$` dans la ligne ; un espace de chaque côté retiré
    /// quand les deux y sont ; contenu fait seulement d'espaces refusé.
    static func doubleDollar(_ chars: [Character], at index: Int, run: Int) -> (latex: String, end: Int)? {
        var cursor = index + run
        while cursor < chars.count {
            guard chars[cursor] == "$" else {
                cursor += 1
                continue
            }
            let length = chars[cursor...].prefix { $0 == "$" }.count
            if length == run {
                var content = String(chars[(index + run)..<cursor])
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                if content.count >= 2, content.first == " ", content.last == " " {
                    content = String(content.dropFirst().dropLast())
                }
                return (content, cursor + length)
            }
            cursor += length
        }
        return nil
    }

    /// Deux morceaux de texte qui se suivent n'en font qu'un.
    private static func append(_ segment: MathSegment, to segments: inout [MathSegment]) {
        if case .text(let next) = segment, case .text(let previous)? = segments.last {
            segments[segments.count - 1] = .text(previous + next)
        } else {
            segments.append(segment)
        }
    }

    /// Retrait d'une ligne (tabulation = 4), comme `MarkdownBlocks`.
    static func leadingIndent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }
}
