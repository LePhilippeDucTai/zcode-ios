import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ComposerCatalogTests {
    private func record(_ folder: String, _ prefix: String) throws -> JSONValue {
        try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
    }

    @Test func commandesReellesDuProjet() throws {
        let presentation = try WorkspacePresentation(json: try record("slash", "004"))
        let names = Set(presentation.slashCommands.map(\.name))
        #expect(names.isSuperset(of: ["goal", "compact", "init", "plan"]))
        #expect(presentation.slashCommands.allSatisfy { $0.source == nil || ["builtin", "custom"].contains($0.source) })
        let goal = try #require(presentation.slashCommands.first { $0.name == "goal" })
        #expect(goal.inputHint?.hasPrefix("/goal") == true)
    }

    @Test func skillsReellesDuProjet() throws {
        let catalog = try SkillReferenceCatalog(json: try record("slash", "006"))
        #expect(catalog.authority == "workspace")
        let probe = try #require(catalog.skills.first { $0.name == "zcode-ios-probe-skill" })
        #expect(probe.scope == .workspace && probe.enabled)
        #expect(try #require(probe.path).contains("zcode-ios-probe-skill"))
    }

    @Test func droitAuxWorkflowsReel() throws {
        let config = try DynamicWorkflowConfig(json: try record("slash", "003"))
        #expect(config.enabled == (config.mode != "disabled"))
        #expect(config.mode == "alwaysOn" && config.source == "remote")
    }

    @Test func sessionInconnueEnErreur() throws {
        let failure = try #require(try Fixtures.records(in: "v3.15.1/slash").first { $0.file.hasPrefix("007") })
        #expect(failure.kind == "error")
        #expect(failure.value["message"]?.stringValue == "Session is not active: sess_zcode-probe-inexistante")
        #expect(failure.value["code"]?.numberValue == -32004)
    }

    @Test func decodageTolerant() throws {
        let presentation = try WorkspacePresentation(json: .object([
            "mode": .string("build"), "inconnu": .bool(true),
            "slashCommands": .array([
                .object(["name": .string("/init"), "description": .string("Crée AGENTS.md")]),
                .object(["description": .string("sans nom")]),
                .object(["name": .string("goal"), "inputHint": .string("/goal [objectif]"), "source": .string("futur")]),
            ]),
        ]))
        #expect(presentation.mode == "build")
        #expect(presentation.slashCommands == [
            SlashCommandInfo(name: "/init", description: "Crée AGENTS.md"),
            SlashCommandInfo(name: "goal", inputHint: "/goal [objectif]", source: "futur"),
        ])
        let catalog = try SkillReferenceCatalog(json: .object(["skills": .array([
            .object(["id": .string("a"), "name": .string("a"), "path": .string("/p/a"), "scope": .string("équipe")]),
            .object(["id": .string("b"), "name": .string("b")]),
            .object(["name": .string("sans-id"), "path": .string("/p/c")]),
        ])]))
        #expect(catalog.authority == nil)
        // Une skill sans chemin est gardée (« $nom » seul) ; sans id ou sans nom, elle est écartée.
        #expect(catalog.skills == [
            SkillReference(id: "a", name: "a", path: "/p/a", scope: SkillScope(rawValue: "équipe")),
            SkillReference(id: "b", name: "b", scope: SkillScope(rawValue: "")),
        ])
        let closed = try DynamicWorkflowConfig(json: .object([:]))
        #expect(!closed.enabled && closed.mode == "disabled")
        #expect(throws: V4DecodingError.invalid("readWorkspacePresentation")) { try WorkspacePresentation(json: .string("?")) }
        #expect(throws: V4DecodingError.invalid("getSkillReferenceCatalog")) { try SkillReferenceCatalog(json: .null) }
        #expect(throws: V4DecodingError.invalid("getDynamicWorkflowClientConfig")) { try DynamicWorkflowConfig(json: .array([])) }
    }
}
