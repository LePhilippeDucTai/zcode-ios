import Foundation
import Testing
import ZCodeAppCore

/// Vecteurs des tests TS de ZCode Web 3.15.1 (`packages/ui/test/messageResponseStreamdownMode.test.ts`) et règles de
/// `message.tsx` : le web remplace par `\$` chaque `$` qui n'ouvre pas une formule probable.
struct MathTextTests {
    @Test func vecteursDuWeb() {
        // « renders single-dollar inline math as KaTeX » : les deux paires restent des formules.
        let chinese = "其中 $c(\\mathbf{r})$ 是声速，$\\omega=2\\pi f$ 是角频率。"
        #expect(MathText.normalizeSingleDollarMathInText(chinese) == chinese)
        // « keeps paired currency dollars as text » : contenu « 5 today and » bordé d'un espace ; le second `$` n'a
        // pas de fermant et reste tel quel.
        #expect(MathText.normalizeSingleDollarMathInText("Pricing is $5 today and $10 tomorrow.")
                == "Pricing is \\$5 today and $10 tomorrow.")
        // « keeps compact currency ranges as text »
        #expect(MathText.normalizeSingleDollarMathInText("Pricing is $5-$10 depending on usage.")
                == "Pricing is \\$5-$10 depending on usage.")
        // « keeps paired shell environment dollars as text »
        #expect(MathText.normalizeSingleDollarMathInText("Use $HOME and $PATH to inspect environment variables.")
                == "Use \\$HOME and $PATH to inspect environment variables.")
    }

    @Test(arguments: [
        ("x", true), ("ab", true), ("x2", true), ("abc", true), ("abcd", false), ("AB", false), ("42", true),
        ("3.14", true), ("HOME", false), ("a b", false), (" x", false), ("x ", false), ("x\ny", false), ("", false),
        ("\\alpha", true), ("a+b", true), ("f(x)", true), ("α", true), ("Ω", true), ("é", false),
    ])
    func formuleProbable(content: String, expected: Bool) {
        #expect(MathText.isLikelySingleDollarMath(content) == expected)
    }

    @Test func formulesEnLigne() {
        #expect(MathText.segments("Soit $x^2$ et $$\\frac{a}{b}$$.") == [
            .text("Soit "), .formula(InlineFormula(latex: "x^2", raw: "$x^2$")), .text(" et "),
            .formula(InlineFormula(latex: "\\frac{a}{b}", raw: "$$\\frac{a}{b}$$")), .text("."),
        ])
    }

    @Test func prixEtVariablesRestentDuTexte() {
        for text in ["Pricing is $5 today and $10 tomorrow.", "Pricing is $5-$10 depending on usage.",
                     "Use $HOME and $PATH to inspect environment variables.", "Coût : \\$x$ reste",
                     "$$x$ non refermé", "Sans dollar"] {
            #expect(MathText.segments(text) == [.text(text)])
        }
        #expect(MathText.segments("").isEmpty)
    }

    @Test func codeEnLigneIntact() {
        #expect(MathText.segments("`$x$` puis $y$") == [
            .text("`$x$` puis "), .formula(InlineFormula(latex: "y", raw: "$y$")),
        ])
        #expect(MathText.normalizeSingleDollarMathOutsideInlineCode("`$HOME $PATH` puis $HOME et $PATH")
                == "`$HOME $PATH` puis \\$HOME et $PATH")
        // Code en ligne non refermé : le web normalise la suite, accent grave compris.
        #expect(MathText.normalizeSingleDollarMathOutsideInlineCode("`a $b c$") == "`a \\$b c$")
    }

    @Test func plusieursLignesEtEspacesDuDoubleDollar() {
        #expect(MathText.segments("a $x$\nb $$ y $$") == [
            .text("a "), .formula(InlineFormula(latex: "x", raw: "$x$")), .text("\nb "),
            .formula(InlineFormula(latex: "y", raw: "$$ y $$")),
        ])
    }

    @Test func sautsDeLigneAutresQueLfRestitues() {
        let crlf = "a $x$\r\nb"
        let segments = MathText.segments(crlf)
        #expect(segments == [.text("a "), .formula(InlineFormula(latex: "x", raw: "$x$")), .text("\r\nb")])
        for text in ["a $x$\u{2028}b", "a $x$\u{2029}b", "a $x$\u{85}b", "a $x$\u{B}b", "a $x$\u{C}b", "a $x$\rb"] {
            let joined = MathText.segments(text).map { segment -> String in
                switch segment {
                case .text(let value): value
                case .formula(let formula): formula.raw
                }
            }.joined()
            #expect(joined == text)
        }
        // U+2028 ne coupe pas la ligne : le contenu « x<U+2028>y » contient une espace, ce n'est pas une formule.
        #expect(MathText.segments("a $x\u{2028}y$") == [.text("a $x\u{2028}y$")])
    }

    @Test func formuleSurDeuxLignesNonReconnue() {
        // Le web examine chaque ligne à part : un `$` ne se referme jamais sur la ligne suivante.
        #expect(MathText.segments("$a\nb$") == [.text("$a\nb$")])
    }

    @Test func grasAutourDUneFormule() throws {
        let prepared = MathMarkdown.prepare("**Soit $x$ réel**")
        #expect(prepared.formulas == [InlineFormula(latex: "x", raw: "$x$")])
        #expect(prepared.markdown == "**Soit \u{E000} réel**")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let pieces = prepared.pieces(of: try AttributedString(markdown: prepared.markdown, options: options))
        guard pieces.count == 3, case .text(let before) = pieces[0], case .formula(0) = pieces[1],
              case .text(let after) = pieces[2] else {
            Issue.record("découpage inattendu : \(pieces)")
            return
        }
        #expect(String(before.characters) == "Soit ")
        #expect(String(after.characters) == " réel")
        #expect(before.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test func caractereDUsagePriveSansFormule() {
        let text = "Icône \u{E000} et $x$"
        let prepared = MathMarkdown.prepare(text)
        #expect(prepared.formulas.isEmpty)
        #expect(prepared.markdown == text)
    }

    @Test func bulleBlocEtTexte() {
        #expect(MathText.messageParts("Calcule\n$$\n\\int_0^1 x\\,dx\n$$\nmerci $x$") == [
            .text("Calcule"), .block("\\int_0^1 x\\,dx"), .text("merci $x$"),
        ])
        #expect(MathText.messageParts("$$\nx") == [.block("x")])
        #expect(MathText.messageParts("$$x$$") == [.text("$$x$$")])
    }

    /// Ni bloc `$$` ni bloc de code : une seule phrase, texte d'origine intact (retours à la ligne de bord compris).
    @Test func bulleSansBlocTexteIntact() {
        #expect(MathText.messageParts("\nmerci $x$\n\n") == [.text("\nmerci $x$\n\n")])
        #expect(MathText.messageParts("a $x$\n\n  b $y$ ") == [.text("a $x$\n\n  b $y$ ")])
    }

    /// Bloc de code seul, sans `$$` : rendu tel quel, sans texte autour.
    @Test func bulleBlocDeCodeSeul() {
        #expect(MathText.messageParts("```swift\nlet x = 1\n```") == [.code("```swift\nlet x = 1\n```")])
    }

    /// `\r\n` : le bloc de code garde ses fins de ligne à l'octet près, les clôtures restent reconnues.
    @Test func bulleCRLFBlocDeCodeALOctetPres() {
        let code = "```\r\n$x$\r\nlet a = 1\r\n```"
        let parts = MathText.messageParts("Voici\r\n" + code + "\r\n$y$")
        #expect(parts == [.text("Voici"), .code(code), .text("$y$")])
        if case .code(let kept)? = parts.dropFirst().first {
            #expect(Array(kept.utf8) == Array(code.utf8))
        }
        #expect(MathText.messageParts("Calcule\r\n$$\r\nx^2\r\n$$\r\nfin") == [
            .text("Calcule"), .block("x^2"), .text("fin"),
        ])
    }

    @Test func bulleBlocDeCodeIntact() {
        #expect(MathText.messageParts("```\n$x$\n```\n$y$") == [.code("```\n$x$\n```"), .text("$y$")])
        #expect(MathText.messageParts("~~~~\n$$\n~~~\n~~~~") == [.code("~~~~\n$$\n~~~\n~~~~")])
    }
}
