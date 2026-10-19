import Testing
import ZCodeAppCore

struct SlashInputTests {
    @Test func motEnCours() {
        #expect(SlashInput.activeTrigger(before: "/") == SlashTrigger(query: "", start: 0))
        #expect(SlashInput.activeTrigger(before: "/pla") == SlashTrigger(query: "pla", start: 0))
        #expect(SlashInput.activeTrigger(before: "Lance /go") == SlashTrigger(query: "go", start: 6))
        #expect(SlashInput.activeTrigger(before: "ligne\n/rev") == SlashTrigger(query: "rev", start: 6))
        #expect(SlashInput.activeTrigger(before: "é /é") == SlashTrigger(query: "é", start: 2))
    }

    @Test func slashDansUnMotNOuvrePas() {
        for text in ["src/a", "https://x.y/z", "a//b", "/goal/x", "/goal ", "/go@x", "/go$x", "/go#x", "", "texte"] {
            #expect(SlashInput.activeTrigger(before: text) == nil, "\(text)")
        }
    }

    @Test func remplacementDuMotEnCours() {
        #expect(SlashInput.replace(before: "/pla", after: "", with: "/plan")
            == SlashReplacement(text: "/plan ", cursor: 6))
        #expect(SlashInput.replace(before: "Vois /rev", after: " et dis-moi", with: "$review-agent")
            == SlashReplacement(text: "Vois $review-agent  et dis-moi", cursor: 19))
        #expect(SlashInput.replace(before: "pas de mot", after: "", with: "/plan") == nil)
    }

    @Test func remplacementAbsorbeLaFinDuMotChoisi() {
        // `/go|al` : la fin du nom est absorbée ; `/goal|xyz` : le texte collé qui n'est pas le nom reste.
        #expect(SlashInput.replace(before: "/go", after: "al suite", with: "/goal")
            == SlashReplacement(text: "/goal  suite", cursor: 6))
        #expect(SlashInput.replace(before: "/goal", after: "xyz", with: "/goal")
            == SlashReplacement(text: "/goal xyz", cursor: 6))
        // Requête vide : rien n'est absorbé.
        #expect(SlashInput.replace(before: "/", after: "texte", with: "/init")
            == SlashReplacement(text: "/init texte", cursor: 6))
    }
}
