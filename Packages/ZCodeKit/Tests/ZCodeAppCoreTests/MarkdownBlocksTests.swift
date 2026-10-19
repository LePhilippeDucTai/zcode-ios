import Testing
import ZCodeAppCore
import ZCodeWire

struct MarkdownBlocksTests {
    @Test func texteEtBlocsDeCode() {
        let markdown = "Voici :\n\n```swift\nlet x = 1\n```\nEt **voilà**."
        #expect(MarkdownBlocks.split(markdown) == [
            .text("Voici :"), .code(language: "swift", code: "let x = 1"), .text("Et **voilà**."),
        ])
    }

    @Test func blocNonRefermePendantLeStreaming() {
        #expect(MarkdownBlocks.split("Début\n```\nls -la") == [.text("Début"), .code(language: nil, code: "ls -la")])
    }

    @Test func texteVide() {
        #expect(MarkdownBlocks.split("").isEmpty)
    }

    @Test func jsonLisible() {
        let json = JSONValue.object(["b": .number(1), "a": .string("x/y")])
        #expect(json.prettyText == "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
    }

    @Test func blocsCourants() {
        let markdown = """
        ## Plan

        1. Ajouter le test
        2. Corriger **le bug**
           avec une suite
        - [ ] à faire
        - [x] fait
          - sous-point

        > Citation
        sur deux lignes

        ---
        | Fichier | État |
        |:--|--:|
        | a.swift | modifié |
        Fin.
        """
        #expect(MarkdownBlocks.split(markdown) == [
            .heading(level: 2, text: "Plan"),
            .listItem(marker: "1.", depth: 0, text: "Ajouter le test"),
            .listItem(marker: "2.", depth: 0, text: "Corriger **le bug**\navec une suite"),
            .listItem(marker: "☐", depth: 0, text: "à faire"),
            .listItem(marker: "☑", depth: 0, text: "fait"),
            .listItem(marker: "•", depth: 1, text: "sous-point"),
            .quote("Citation\nsur deux lignes"),
            .rule,
            .table([["Fichier", "État"], ["a.swift", "modifié"]]),
            .text("Fin."),
        ])
    }

    @Test func paragraphesSepares() {
        #expect(MarkdownBlocks.split("Un\ndeux\n\nTrois") == [.text("Un\ndeux"), .text("Trois")])
        #expect(MarkdownBlocks.split("*italique* et **gras**\n* point") == [
            .text("*italique* et **gras**"), .listItem(marker: "•", depth: 0, text: "point"),
        ])
        #expect(MarkdownBlocks.split("C# et F#\n# Titre C#\n### Fin ###") == [
            .text("C# et F#"), .heading(level: 1, text: "Titre C#"), .heading(level: 3, text: "Fin"),
        ])
    }

    @Test func cloturesVariees() {
        #expect(MarkdownBlocks.split("~~~\na\n~~~") == [.code(language: nil, code: "a")])
        #expect(MarkdownBlocks.split("````md\n```\nx\n```\n````") == [.code(language: "md", code: "```\nx\n```")])
        #expect(MarkdownBlocks.split("Texte\r\n```sh\r\nls\r\n```\r\n") == [.text("Texte"), .code(language: "sh", code: "ls")])
        #expect(MarkdownBlocks.split("```\n# pas un titre\n- pas une liste\n```") == [
            .code(language: nil, code: "# pas un titre\n- pas une liste"),
        ])
    }

    @Test func blocDollar() {
        #expect(MarkdownBlocks.split("Avant\n$$\na^2+b^2=c^2\n$$\nAprès") == [
            .text("Avant"), .math("a^2+b^2=c^2"), .text("Après"),
        ])
        // Texte après `$$` à l'ouverture : « méta » ignorée par le web (micromark `mathFlow`).
        #expect(MarkdownBlocks.split("$$ ignorée\nx\n$$") == [.math("x")])
    }

    @Test func blocDollarSurUneLigneResteEnLigne() {
        // Méta contenant `$` : pas de bloc ; le web rend `$$x^2$$` en ligne dans son paragraphe.
        #expect(MarkdownBlocks.split("$$x^2$$") == [.text("$$x^2$$")])
    }

    @Test func blocMath() {
        #expect(MarkdownBlocks.split("```math\n\\sqrt{2}\n```") == [.math("\\sqrt{2}")])
    }

    @Test func blocDollarNonReferme() {
        // Comme le web : un `$$` non refermé prend toute la suite.
        #expect(MarkdownBlocks.split("Texte\n$$\nx\n\nsuite") == [.text("Texte"), .math("x\n\nsuite")])
    }

    @Test func fermetureAuMoinsAussiLongue() {
        #expect(MarkdownBlocks.split("$$$\nx\n$$\n$$$$") == [.math("x\n$$")])
        #expect(MarkdownBlocks.split("$$\n$$").isEmpty)
    }

    @Test func dollarDansUnBlocDeCode() {
        #expect(MarkdownBlocks.split("```\n$$\nx\n$$\n```") == [.code(language: nil, code: "$$\nx\n$$")])
    }
}
