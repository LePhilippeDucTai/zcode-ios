import Testing
import ZCodeAppCore

struct SyntaxHighlighterTests {
    func tokens(_ code: String, _ language: String) -> [SyntaxToken] {
        SyntaxHighlighter.tokens(code, language: language)
    }

    @Test func swiftMotCleChaineEchappeeEtCommentaire() {
        #expect(tokens("let name = \"a\\\"b\" // fin", "swift") == [
            SyntaxToken(.keyword, "let"), SyntaxToken(.plain, " name = "), SyntaxToken(.string, "\"a\\\"b\""),
            SyntaxToken(.plain, " "), SyntaxToken(.comment, "// fin"),
        ])
    }

    @Test func typesEnMajusculeEtNombres() {
        #expect(tokens("var x: Int = 42", "swift") == [
            SyntaxToken(.keyword, "var"), SyntaxToken(.plain, " x: "), SyntaxToken(.type, "Int"),
            SyntaxToken(.plain, " = "), SyntaxToken(.number, "42"),
        ])
    }

    @Test func pythonChaineTripleEtCommentaire() {
        #expect(tokens("def f():\n    \"\"\"doc\n    \"\"\"\n    return None  # fin", "python") == [
            SyntaxToken(.keyword, "def"), SyntaxToken(.plain, " f():\n    "), SyntaxToken(.string, "\"\"\"doc\n    \"\"\""),
            SyntaxToken(.plain, "\n    "), SyntaxToken(.keyword, "return"), SyntaxToken(.plain, " "),
            SyntaxToken(.keyword, "None"), SyntaxToken(.plain, "  "), SyntaxToken(.comment, "# fin"),
        ])
    }

    @Test func shellDieseEtGuillemetsSimples() {
        #expect(tokens("echo a#b # vrai", "bash") == [SyntaxToken(.plain, "echo a#b "), SyntaxToken(.comment, "# vrai")])
        #expect(tokens("echo 'a\\' fi", "zsh") == [
            SyntaxToken(.plain, "echo "), SyntaxToken(.string, "'a\\'"), SyntaxToken(.plain, " "), SyntaxToken(.keyword, "fi"),
        ])
    }

    @Test func jsonClesValeursEtNombres() {
        #expect(tokens("{\"a\": true, \"n\": -1.5}", "json") == [
            SyntaxToken(.plain, "{"), SyntaxToken(.string, "\"a\""), SyntaxToken(.plain, ": "), SyntaxToken(.keyword, "true"),
            SyntaxToken(.plain, ", "), SyntaxToken(.string, "\"n\""), SyntaxToken(.plain, ": -"), SyntaxToken(.number, "1.5"),
            SyntaxToken(.plain, "}"),
        ])
    }

    @Test func typescriptGabaritMultiligneEtAlias() {
        #expect(tokens("const s = `a\n${b}`", "TSX") == [
            SyntaxToken(.keyword, "const"), SyntaxToken(.plain, " s = "), SyntaxToken(.string, "`a\n${b}`"),
        ])
    }

    @Test func goEtRust() {
        #expect(tokens("func f() { s := `x` }", "go") == [
            SyntaxToken(.keyword, "func"), SyntaxToken(.plain, " f() { s := "), SyntaxToken(.string, "`x`"),
            SyntaxToken(.plain, " }"),
        ])
        #expect(tokens("fn main() { let c = 'a'; }", "rs") == [
            SyntaxToken(.keyword, "fn"), SyntaxToken(.plain, " main() { "), SyntaxToken(.keyword, "let"),
            SyntaxToken(.plain, " c = 'a'; }"),
        ])
    }

    @Test func commentairesDeBloc() {
        #expect(tokens("/* a\nb */ let", "swift") == [
            SyntaxToken(.comment, "/* a\nb */"), SyntaxToken(.plain, " "), SyntaxToken(.keyword, "let"),
        ])
        #expect(tokens("x /* a", "swift") == [SyntaxToken(.plain, "x "), SyntaxToken(.comment, "/* a")])
    }

    @Test func chaineNonFermeeSArreteEnFinDeLigne() {
        #expect(tokens("\"abc\nlet", "swift") == [
            SyntaxToken(.string, "\"abc"), SyntaxToken(.plain, "\n"), SyntaxToken(.keyword, "let"),
        ])
        #expect(tokens("\"a\\", "swift") == [SyntaxToken(.string, "\"a\\")])          // barre oblique finale
        #expect(tokens("// dans \"une\" chaîne", "go") == [SyntaxToken(.comment, "// dans \"une\" chaîne")])
        #expect(tokens("s = \"// pas un commentaire\"", "ts") == [
            SyntaxToken(.plain, "s = "), SyntaxToken(.string, "\"// pas un commentaire\""),
        ])
    }

    @Test func langageInconnuOuTropLong() {
        #expect(SyntaxHighlighter.tokens("let x = 1", language: nil) == [SyntaxToken(.plain, "let x = 1")])
        #expect(SyntaxHighlighter.tokens("let x = 1", language: "cobol") == [SyntaxToken(.plain, "let x = 1")])
        #expect(SyntaxHighlighter.tokens("", language: "swift").isEmpty)
        let long = String(repeating: "let ", count: 5_001)                             // 20 004 caractères
        #expect(SyntaxHighlighter.tokens(long, language: "swift") == [SyntaxToken(.plain, long)])
    }

    @Test func jetonsRecomposentLeCode() {
        let samples: [(String, String)] = [
            ("swift", "struct A: View {\n  @State var n = 0x1F // c\n  let s = \"\"\"\n  é \\(n)\n  \"\"\"\n}"),
            ("typescript", "export const f = async (a: number): Promise<void> => { /* x */ await g(`${a}`, 'b') }"),
            ("python", "class A:\n    x = '''y\n'''  # z\n    def f(self): return 3.14"),
            ("bash", "for f in *.swift; do echo \"$f\" | grep -c 'let'; done # fin\n"),
            ("json", "[{\"k\": [1, 2e3, null]}, \"\\u00e9\"]"),
            ("rust", "impl<'a> T for S<'a> { fn f(&self) -> u8 { b'x' as u8 } } /* non fermé"),
            ("go", "package main\nimport \"fmt\"\nfunc main() { fmt.Println(`brut\\n`, 'r') }"),
            ("swift", "\"non fermée\n\"\"\" non fermée non plus"),
        ]
        for (language, code) in samples {
            #expect(tokens(code, language).map(\.text).joined() == code, "\(language)")
            #expect(!tokens(code, language).contains { $0.text.isEmpty })
        }
    }
}
