import Testing
import ZCodeAppCore

struct SlashTokensTests {
    private let link = "[$review-agent](/w/.zcode/skills/review-agent/SKILL.md)"

    @Test func jetonIntactRemplace() {
        var tokens = SlashTokens()
        tokens.record("$review-agent", sendAs: link)
        tokens.record("@Explore", sendAs: "@Explore")
        #expect(tokens.expand("$review-agent relis puis @Explore cherche") == "\(link) relis puis @Explore cherche")
        #expect(tokens.expand("$review-agent") == link)
        #expect(tokens.expand("fin\n$review-agent") == "fin\n" + link)
    }

    @Test func seulsLesJetonsIntactsSontRemplaces() {
        var tokens = SlashTokens()
        tokens.record("$review-agent", sendAs: link)
        #expect(tokens.expand("$review-agentx") == "$review-agentx")               // modifié
        #expect(tokens.expand("x$review-agent") == "x$review-agent")               // dans un mot
        #expect(tokens.expand("$review-agent, merci") == "$review-agent, merci")   // ponctuation collée : plus un mot entier
        #expect(tokens.expand("rien") == "rien")                                   // effacé
        #expect(SlashTokens().expand("$review-agent") == "$review-agent")          // tapé à la main, jamais inséré
    }

    @Test func tableVidee() {
        var tokens = SlashTokens()
        tokens.record("$a", sendAs: "[$a](/a)")
        #expect(!tokens.isEmpty && tokens.replacements == ["$a": "[$a](/a)"])
        tokens.removeAll()
        #expect(tokens.isEmpty && tokens.expand("$a") == "$a")
    }
}
