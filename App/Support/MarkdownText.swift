import SwiftUI
import ZCodeAppCore

/// Taille du texte Markdown : réponse (corps, titres gradués) ou réflexion (une taille en dessous, titres à la même
/// taille en demi-gras). La couleur est posée par l'appelant (`.foregroundStyle`).
enum MarkdownStyle: Equatable {
    case answer, reasoning

    var body: Font { self == .answer ? ZCodeTypography.body : ZCodeTypography.reasoning }

    func heading(_ level: Int) -> Font {
        switch self {
        case .answer: level == 1 ? ZCodeTypography.heading : level == 2 ? ZCodeTypography.subheading : ZCodeTypography.smallHeading
        case .reasoning: ZCodeTypography.reasoningHeading
        }
    }

    /// Formules d'un paragraphe, d'une liste, d'un tableau : taille du corps ; grises dans une réflexion.
    var formula: FormulaStyle { FormulaStyle(textStyle: self == .answer ? .body : .callout, secondary: self == .reasoning) }

    /// Formules d'une citation : grises comme son texte.
    var quoteFormula: FormulaStyle { FormulaStyle(textStyle: formula.textStyle, secondary: true) }

    func headingFormula(_ level: Int) -> FormulaStyle {
        switch self {
        case .answer: FormulaStyle(textStyle: level == 1 ? .title3 : level == 2 ? .headline : .subheadline, secondary: false)
        case .reasoning: FormulaStyle(textStyle: .callout, secondary: true)
        }
    }
}

/// Markdown d'une réponse terminée, d'un plan ou d'un fichier `.md` : découpé en blocs (`MarkdownBlocks`), le Markdown
/// en ligne de chaque bloc via `AttributedString(markdown:)`.
/// L'isolation d'un delta à sa seule cellule vient de `ChatEntryView` (`Equatable`, `.equatable()`) : `LazyVStack` recrée
/// la cellule en entrant dans la zone visible, et le découpage est alors refait même sans changement de texte.
struct MarkdownText: View, Equatable {
    let markdown: String
    var style: MarkdownStyle = .answer

    var body: some View {
        VStack(alignment: .leading, spacing: style == .answer ? 10 : 8) {
            ForEach(Array(MarkdownBlocks.split(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, style: style)
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Bloc de code (Markdown, cartes d'outils, cartes non prises en charge) : en-tête avec le langage et « Copier »,
/// code coloré selon le langage (`SyntaxHighlighter` ; texte brut si inconnu ou trop long).
struct CodeBlock: View {
    /// `.regular` : réponses, dock d'autorisation, cartes non prises en charge. `.compact` : cartes d'outils (code en
    /// `ZCodeTypography.toolCode`, marges et en-tête resserrés).
    enum Style {
        case regular, compact
    }

    let language: String?
    let code: String
    /// Ce que copie le bouton : par défaut `code` ; la commande seule quand l'affichage la précède de « $ », la sortie
    /// entière quand l'affichage est tronqué.
    let copyText: String
    /// Calculé à la création du bloc (à chaque recréation de la vue : `MarkdownText` et les cartes recréent leurs blocs en entrant
    /// dans la zone visible).
    private let highlighted: AttributedString
    let style: Style
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    init(language: String?, code: String, copyText: String? = nil, style: Style = .regular) {
        self.language = language
        self.code = code
        self.copyText = copyText ?? code
        self.style = style
        highlighted = Self.highlighted(code, language: language)
    }

    private var compact: Bool { style == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(spacing: compact ? 6 : 8) {
                if let language {
                    Text(language).font(compact ? ZCodeTypography.toolStatus.monospaced() : ZCodeTypography.monoCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(compact ? ZCodeTypography.toolStatus : .caption)
                        .padding(.vertical, compact ? 2 : 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copié" : "Copier le code")
                .accessibilityIdentifier("code-copy")
            }
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(compact ? ZCodeTypography.toolCode : ZCodeTypography.code)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: compact ? 8 : 10))
    }

    /// Copie d'un toucher ; la coche reste 1,5 s (un nouveau toucher repart de zéro).
    private func copy() {
        UIPasteboard.general.string = copyText
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    static func highlighted(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for token in SyntaxHighlighter.tokens(code, language: language) {
            var piece = AttributedString(token.text)
            if let color = ZCodeSyntaxColors.color(for: token.kind) { piece.foregroundColor = color }
            result += piece
        }
        return result
    }
}

/// Un bloc Markdown ; le Markdown en ligne (gras, code, liens) reste rendu par `AttributedString`, les formules en
/// images (`MathInlineText`, `MathBlockView`).
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case .text(let text):
            MathInlineText(source: text, style: style.formula)
                .font(style.body)
                .lineSpacing(3)
                .textSelection(.enabled)
        case .heading(let level, let text):
            MathInlineText(source: text, style: style.headingFormula(level))
                .font(style.heading(level))
                .lineSpacing(2)
                .padding(.top, 6)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(style.body).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                MathInlineText(source: text, style: style.formula)
                    .font(style.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            MathInlineText(source: text, style: style.quoteFormula)
                .font(style.body)
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .rule:
            Divider()
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .math(let latex):
            MathBlockView(latex: latex, style: style.formula).font(style.body)
        case .table(let rows):
            MarkdownTable(rows: rows, font: style.body, formula: style.formula)
        }
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]
    let font: Font
    let formula: FormulaStyle

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            MathInlineText(source: cell, style: formula).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .font(font)
        }
    }
}
