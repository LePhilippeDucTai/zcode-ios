import SwiftUI
import UIKit
import ZCodeAppCore

/// Taille et teinte du texte qui entoure une formule ; la clé du rendu en découle pour l'environnement courant.
struct FormulaStyle: Equatable {
    let textStyle: UIFont.TextStyle
    /// Gris (`secondaryLabel`) : réflexions, citations.
    let secondary: Bool

    static let bubble = FormulaStyle(textStyle: .body, secondary: false)

    func key(latex: String, display: Bool, dynamicTypeSize: DynamicTypeSize, colorScheme: ColorScheme,
             scale: CGFloat) -> FormulaKey {
        let sizeTraits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let size = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: sizeTraits).pointSize
        let color = (secondary ? UIColor.secondaryLabel : UIColor.label)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        return FormulaKey(latex: latex, display: display, fontSize: size, color: Self.css(color), scale: scale)
    }

    static func css(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgba(\(byte(red)),\(byte(green)),\(byte(blue)),\(String(format: "%.3f", Double(min(max(alpha, 0), 1)))))"
    }
}

/// Texte d'un bloc Markdown ou de la bulle, formules en ligne comprises : un seul `Text` (sélection, retours à la
/// ligne gardés), chaque formule une image posée sur la ligne de base. Tant qu'une image n'est pas prête, la source
/// brute (`$…$`) s'affiche ; la phrase se redessine une fois, quand ses images sont arrivées (état de cette seule vue :
/// la cellule `ChatEntryView` reste `Equatable` sur son texte). VoiceOver lit la phrase avec la source LaTeX.
struct MathInlineText: View {
    let source: String
    /// `true` : Markdown en ligne (réponses, réflexions, titres, tableaux) ; `false` : texte brut (bulle).
    var markdown = true
    let style: FormulaStyle
    /// Résultats obtenus par cette vue, `.unavailable` compris : une formule dont le rendu a dépassé le délai n'est
    /// pas redemandée tant que la vue vit (source brute ; nouvel essai au prochain affichage).
    @State private var rendered: [FormulaKey: FormulaResult] = [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let prepared = MathMarkdown.prepare(source)
        if prepared.formulas.isEmpty {
            Text(markdown ? MarkdownText.attributed(source) : AttributedString(source))
        } else {
            let keys = prepared.formulas.map {
                style.key(latex: $0.latex, display: false, dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme,
                          scale: displayScale)
            }
            composed(prepared, keys: keys)
                .task(id: keys) { await load(keys) }
        }
    }

    /// `Text + Text` est déprécié en iOS 26 : composition par interpolation.
    private func composed(_ prepared: MathMarkdown, keys: [FormulaKey]) -> Text {
        let attributed = markdown ? MarkdownText.attributed(prepared.markdown) : AttributedString(prepared.markdown)
        var spoken = ""
        var text = Text(verbatim: "")
        for piece in prepared.pieces(of: attributed) {
            switch piece {
            case .text(let run):
                spoken += String(run.characters)
                text = Text("\(text)\(Text(run))")
            case .formula(let rank):
                let formula = prepared.formulas[rank]
                spoken += formula.latex
                text = Text("\(text)\(formulaText(formula, key: keys[rank]))")
            }
        }
        return text.accessibilityLabel(spoken)
    }

    private func formulaText(_ formula: InlineFormula, key: FormulaKey) -> Text {
        switch rendered[key] ?? FormulaRenderer.shared.cached(key) {
        case .image(let image)?:
            Text(Image(uiImage: image.image)).baselineOffset(-image.depth)
        case .failed?:
            Text(verbatim: formula.latex).foregroundStyle(.secondary)
        case .unavailable?, nil:
            Text(verbatim: formula.raw)
        }
    }

    /// Images manquantes demandées dans l'ordre ; un seul redessin, à la fin.
    private func load(_ keys: [FormulaKey]) async {
        var found = rendered
        var changed = false
        for key in keys where found[key] == nil && FormulaRenderer.shared.cached(key) == nil {
            found[key] = await FormulaRenderer.shared.render(key)
            changed = true
            if Task.isCancelled { return }
        }
        if changed { rendered = found }
    }
}

/// Formule en bloc (`$$…$$`, ```` ```math ````) : centrée, défilement horizontal si elle est plus large que l'écran.
struct MathBlockView: View {
    let latex: String
    let style: FormulaStyle
    /// Comme `MathInlineText.rendered` : `.unavailable` gardé ici, sans nouvelle demande tant que la vue vit.
    @State private var rendered: [FormulaKey: FormulaResult] = [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let key = style.key(latex: latex, display: true, dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme,
                            scale: displayScale)
        content(rendered[key] ?? FormulaRenderer.shared.cached(key))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(latex)
            .accessibilityIdentifier("math-formula")
            .task(id: key) {
                guard rendered[key] == nil, FormulaRenderer.shared.cached(key) == nil else { return }
                let result = await FormulaRenderer.shared.render(key)
                if !Task.isCancelled { rendered[key] = result }
            }
    }

    @ViewBuilder
    private func content(_ result: FormulaResult?) -> some View {
        switch result {
        case .image(let formula)?:
            let image = Image(uiImage: formula.image)
            ViewThatFits(in: .horizontal) {
                image
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
        case .failed?:
            Text(verbatim: latex).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .unavailable?, nil:
            Text(verbatim: "$$\n\(latex)\n$$").multilineTextAlignment(.center)
        }
    }
}

/// Bulle de l'utilisateur : texte brut, seules les formules sont rendues ; rien n'est interprété dans un bloc de code.
/// Sans bloc `$$` ni bloc de code, une seule phrase sur le texte entier (`MathText.messageParts` le rend intact) ;
/// sinon un morceau par partie.
struct MathMessageText: View {
    let text: String

    var body: some View {
        if !text.contains("$") {
            Text(text)
        } else {
            let parts = MathText.messageParts(text)
            if parts == [.text(text)] {
                MathInlineText(source: text, markdown: false, style: .bubble)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let chunk):
                            MathInlineText(source: chunk, markdown: false, style: .bubble)
                        case .code(let code):
                            Text(verbatim: code)
                        case .block(let latex):
                            MathBlockView(latex: latex, style: .bubble)
                        }
                    }
                }
            }
        }
    }
}
