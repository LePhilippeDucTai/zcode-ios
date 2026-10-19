import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

private func skill(_ name: String, scope: SkillScope, path: String? = nil, id: String? = nil,
                   description: String = "", enabled: Bool = true) -> SkillReference {
    SkillReference(id: id ?? "\(scope.rawValue):\(name)", name: name, description: description,
                   path: path ?? "/h/.zcode/skills/\(name)/SKILL.md", scope: scope, enabled: enabled)
}

private func agent(_ name: String, scope: String, source: String, enabled: Bool = true, description: String = "d") throws -> AgentSummary {
    try #require(AgentSummary(json: .object([
        "id": .string("\(source):\(scope):\(name)"), "name": .string(name), "path": .string("/h/\(name).md"),
        "description": .string(description), "systemPrompt": .string("s"), "scope": .string(scope),
        "source": .string(source), "enabled": .bool(enabled),
    ])))
}

struct SlashSuggestionsTests {
    @Test func nomDeCommandeNormalise() {
        let entries = SlashSuggestions.commands([
            SlashCommandInfo(name: "/init", description: "Crée AGENTS.md"),
            SlashCommandInfo(name: "goal", description: "Objectif", inputHint: "/goal [objectif]"),
            SlashCommandInfo(name: "plan", description: "Plan", inputHint: "/plan"),
            SlashCommandInfo(name: " / "),
        ])
        #expect(entries.map(\.insertion) == ["/init", "/goal", "/plan"])
        #expect(entries.map(\.hint) == [nil, "/goal [objectif]", nil])                // « /plan » ne dit rien de plus
        #expect(entries.allSatisfy { $0.kind == .command && $0.sendAs == nil })
        #expect(entries.first?.id == "command-init")
    }

    @Test func noteDeCompact() {
        let entries = SlashSuggestions.commands([SlashCommandInfo(name: "compact", description: "Compresse le contexte.")])
        #expect(entries.first?.detail == "Compresse le contexte. Le texte qui suit /compact est ignoré.")
    }

    @Test func noteCompressNommeLaCommande() {
        let entries = SlashSuggestions.commands([SlashCommandInfo(name: "compress", description: "Compresse.")])
        #expect(entries.first?.detail == "Compresse. Le texte qui suit /compress est ignoré.")
    }

    @Test func nomsEnDoubleGardentLePremier() {
        let entries = SlashSuggestions.commands([
            SlashCommandInfo(name: "init", description: "Premier"),
            SlashCommandInfo(name: "/init", description: "Second"),
            SlashCommandInfo(name: "plan", description: "Plan"),
        ])
        #expect(entries.map(\.name) == ["init", "plan"])
        #expect(entries.first?.description == "Premier")
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test func skillsDedoublonneesEtFiltrees() {
        let entries = SlashSuggestions.skills([
            skill("review-agent", scope: .user),
            skill("review-agent", scope: .workspace, path: "/w/.zcode/skills/review-agent/SKILL.md"),
            skill("pdf", scope: .plugin, path: "/h/.zcode/cli/plugins/cache/pdf/SKILL.md"),
            skill("pdf", scope: .user),
            skill("claude-only", scope: .user, path: "/h/.claude/skills/claude-only/SKILL.md"),   // pas de ZCode
            skill("glm-id", scope: .user, path: "/ailleurs/SKILL.md", id: "glm:glm-id"),
            skill("off", scope: .workspace, enabled: false),
        ])
        #expect(entries.map(\.name) == ["review-agent", "pdf", "glm-id"])                // ordre de première apparition
        #expect(entries[0].detail == "Projet")
        #expect(entries[0].sendAs == "[$review-agent](/w/.zcode/skills/review-agent/SKILL.md)")
        #expect(entries[1].insertion == "$pdf" && entries[1].detail == "Plugin")
    }

    @Test func skillSansChemin() {
        let entries = SlashSuggestions.skills([
            SkillReference(id: "user:nue", name: "nue", scope: .user),                    // ni plugin ni glm: : écartée
            SkillReference(id: "plugin:p", name: "plug", scope: .plugin),
            SkillReference(id: "glm:g", name: "glm", scope: .user),
        ])
        #expect(entries.map(\.name) == ["plug", "glm"])
        #expect(entries.map(\.sendAs) == ["$plug", "$glm"])
    }

    @Test func sousAgentsDedoublonnes() throws {
        let entries = SlashSuggestions.subagents([
            try agent("Explore", scope: "built-in", source: "built-in", description: "Explore le code"),
            try agent("reviewer", scope: "user", source: "plugin"),
            try agent("reviewer", scope: "user", source: "user"),
            try agent("reviewer", scope: "workspace", source: "user"),
            try agent("off", scope: "user", source: "user", enabled: false),
        ])
        #expect(entries.map(\.name) == ["Explore", "reviewer"])
        #expect(entries[0].detail == "Intégré · Explore le code" && entries[0].sendAs == "@Explore")
        #expect(entries[1].detail == "Projet · d")
    }

    @Test func filtreSansCasseNiAccents() {
        let entries = SlashSuggestions.commands([
            SlashCommandInfo(name: "init", description: "Crée le fichier de planification"),
            SlashCommandInfo(name: "plan", description: "Mode plan"),
            SlashCommandInfo(name: "replan", description: "Refait"),
            SlashCommandInfo(name: "goal", description: "Objectif"),
        ])
        #expect(SlashSuggestions.filter(entries, query: "PLAN").map(\.name) == ["plan", "replan", "init"])
        #expect(SlashSuggestions.filter(entries, query: "CRÉE").map(\.name) == ["init"])     // description, sans accents
        #expect(SlashSuggestions.filter(entries, query: "cree").map(\.name) == ["init"])
        #expect(SlashSuggestions.filter(entries, query: "zzz").isEmpty)
        #expect(SlashSuggestions.filter(entries, query: "").map(\.name) == ["init", "plan", "replan", "goal"])
    }

    @Test func sectionsDansLOrdreSansSourceEnEchec() throws {
        let commands = SlashSuggestions.commands([SlashCommandInfo(name: "goal")])
        let subagents = SlashSuggestions.subagents([try agent("Explore", scope: "built-in", source: "built-in")])
        let sections = SlashSuggestions.sections(commands: commands, skills: nil, subagents: subagents, query: "")
        #expect(sections.map(\.title) == ["Commandes", "Sous-agents"])
        #expect(SlashSuggestions.sections(commands: commands, skills: [], subagents: subagents, query: "expl").map(\.kind) == [.subagent])
    }

    @Test func texteEnvoyeCommeLeWeb() {
        #expect(SlashMarkdown.skill(name: "a", path: nil) == "$a")
        #expect(SlashMarkdown.skill(name: "a", path: "/p/a/SKILL.md") == "[$a](/p/a/SKILL.md)")
        #expect(SlashMarkdown.skill(name: "a", path: "skills/a.md") == "[$a](./skills/a.md)")
        #expect(SlashMarkdown.skill(name: "a]b", path: "/p/x>y") == "[$a\\]b](/p/x\\>y)")
        #expect(SlashMarkdown.subagent(name: "Explore") == "@Explore")
    }
}
