import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SubagentsTests {
    private func record(_ folder: String, _ prefix: String) throws -> JSONValue {
        try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
    }

    @Test func listeUtilisateurReelle() throws {
        let list = try AgentsListResult(json: try record("subagents-read", "001"))
        #expect(list.userScopeAvailable)
        let explore = try #require(list.agents.first { $0.name == "Explore" })
        #expect(explore.source == .builtIn && explore.readOnly && !explore.isEditable && !explore.canToggleEnabled)
        #expect(list.diagnostics.count == 4 && list.diagnostics.first?.code == "agent_ambiguous_name")
        #expect(list.diagnostics.first?.path != nil)
    }

    @Test func agentDeProjetReel() throws {
        let list = try AgentsListResult(json: try record("subagents-lifecycle", "005"))
        let agent = try #require(list.userAgents.first { $0.id == "user:workspace:zcode-ios-probe-agent" })
        #expect(agent.scope == .workspace && agent.isEditable && !agent.canToggleEnabled)
        #expect(agent.tools == ["Read", "Grep"] && agent.color == .cyan && agent.projectPath != nil)
        #expect(list.pluginAgents.count == 4)
    }

    @Test func agentUtilisateurDesactive() throws {
        let list = try AgentsListResult(json: try record("subagents-lifecycle", "010"))
        let agent = try #require(list.agents.first { $0.id == "user:user:zcode-ios-probe-user" })
        #expect(!agent.enabled && agent.canToggleEnabled)
    }

    @Test func agentDePluginAvecModele() throws {
        let list = try AgentsListResult(json: try record("subagents-lifecycle", "005"))
        let agent = try #require(list.pluginAgents.first { $0.name == "pdf:visual-judge" })
        #expect(agent.source == .plugin && agent.readOnly && !agent.isEditable)
        #expect(agent.pluginId == "pdf@zcode-plugins-official" && agent.pluginName == "pdf")
        #expect(agent.modelSelection?.modelId == "GLM-5.3-Flash")
        #expect(agent.defaultModelSelection?.options?.reasoningLevel == "max")
        #expect(agent.modelSelectionOverride == nil)
    }

    @Test func decodageTolerant() throws {
        let list = try AgentsListResult(json: .object([
            "agents": .array([
                .object([
                    "id": .string("x:y:z"), "name": .string("z"), "path": .string("/p/z.md"),
                    "color": .string("teal"), "scope": .string("team"), "source": .string("user"),
                    "futur": .string("ignoré"),
                ]),
                .object(["name": .string("sans-id"), "path": .string("/p/a.md")]),
                .string("pas un objet"),
            ]),
        ]))
        #expect(list.agents.count == 1)
        let agent = list.agents[0]
        #expect(agent.color?.rawValue == "teal")
        #expect(agent.scope.rawValue == "team")
        #expect(!agent.isEditable)
        #expect(agent.enabled)
        #expect(list.userScopeAvailable && list.userAgents.isEmpty && list.pluginAgents.isEmpty)
        #expect(throws: V4DecodingError.invalid("subagents.list")) { try AgentsListResult(json: .string("?")) }
    }

    @Test func capaciteEtDiagnostics() throws {
        let list = try AgentsListResult(json: .object([
            "capability": .object(["userScopeAvailable": .bool(false), "userScopeReason": .string("lecture seule")]),
            "diagnostics": .array([.object(["code": .string("c"), "message": .string("m")])]),
        ]))
        #expect(!list.userScopeAvailable && list.userScopeReason == "lecture seule")
        #expect(list.diagnostics == [AgentDiagnostic(code: "c", message: "m", path: nil)])
    }

    @Test func gardesDEdition() throws {
        func agent(source: String, scope: String, readOnly: Bool) -> AgentSummary? {
            AgentSummary(json: .object([
                "id": .string("i"), "name": .string("n"), "path": .string("/p"),
                "source": .string(source), "scope": .string(scope), "readOnly": .bool(readOnly),
            ]))
        }
        let user = try #require(agent(source: "user", scope: "user", readOnly: false))
        #expect(user.isEditable && user.canToggleEnabled)
        let project = try #require(agent(source: "user", scope: "workspace", readOnly: false))
        #expect(project.isEditable && !project.canToggleEnabled)
        let locked = try #require(agent(source: "user", scope: "user", readOnly: true))
        #expect(!locked.isEditable && !locked.canToggleEnabled)
        let plugin = try #require(agent(source: "plugin", scope: "user", readOnly: false))
        #expect(!plugin.isEditable)
        let builtIn = try #require(agent(source: "built-in", scope: "built-in", readOnly: false))
        #expect(!builtIn.isEditable)
    }

    private func fullAgent() throws -> AgentSummary {
        let selection: JSONValue = .object([
            "providerId": .string("p"), "modelId": .string("m"),
            "options": .object(["reasoningLevel": .string("high")]),
        ])
        return try #require(AgentSummary(json: .object([
            "id": .string("user:user:full"), "name": .string("full"), "description": .string("d"),
            "systemPrompt": .string("s"), "path": .string("/h/.zcode/agents/full.md"),
            "color": .string("pink"), "modelSelection": selection,
            "tools": .array([.string("Read")]), "disallowedTools": .array([.string("Bash")]),
            "skills": .array([.string("pdf")]), "injectAgentsMd": .bool(false),
            "permissionMode": .string("acceptEdits"), "maxTurns": .number(7), "background": .bool(true),
            "mcpServers": .array([.object(["name": .string("srv")])]),
            "scope": .string("user"), "source": .string("user"), "enabled": .bool(true), "readOnly": .bool(false),
        ])))
    }

    @Test func configRenvoieTousLesChamps() throws {
        let agent = try fullAgent()
        #expect(agent.maxTurns == 7 && agent.permissionMode == .acceptEdits && agent.modelSelection?.options?.reasoningLevel == "high")
        let json = try #require(SubAgentConfig(agent).json.objectValue)
        #expect(Set(json.keys) == [
            "name", "description", "systemPrompt", "color", "modelSelection", "tools", "disallowedTools", "injectAgentsMd",
            "skills", "permissionMode", "maxTurns", "background", "mcpServers",
        ])
        #expect(!json.values.contains(.null))
        #expect(json["modelSelection"]?["options"]?["reasoningLevel"] == .string("high"))
        #expect(json["mcpServers"] == .array([.object(["name": .string("srv")])]))
        #expect(json["maxTurns"] == .number(7) && json["color"] == .string("pink") && json["permissionMode"] == .string("acceptEdits"))
        #expect(json["injectAgentsMd"] == .bool(false) && json["background"] == .bool(true))
    }

    @Test func configMinimale() {
        let config = SubAgentConfig(name: "a-b", description: "d", systemPrompt: "s")
        #expect(config.json == .object(["name": .string("a-b"), "description": .string("d"), "systemPrompt": .string("s")]))
    }

    @Test func configGardeLesValeursRecues() throws {
        // Une description échappée par l'hôte est gardée telle quelle (le formulaire s'en charge).
        let list = try AgentsListResult(json: try record("subagents-lifecycle", "007"))
        let agent = try #require(list.userAgents.first { $0.name == "zcode-ios-probe-agent-v2" })
        #expect(SubAgentConfig(agent).description == agent.description)
        #expect(agent.description.contains("\\"))
    }

    @Test func couleursEtModes() {
        #expect(AgentColor.webOrder.map(\.rawValue) == ["yellow", "red", "orange", "green", "cyan", "blue", "purple", "pink"])
        #expect(AgentPermissionMode.defaultMode.rawValue == "default")
        #expect(AgentScope.builtIn.rawValue == "built-in" && AgentSource.builtIn.rawValue == "built-in")
    }

    @Test func portee() {
        #expect(ExtensionScope.user.wireName == "user" && ExtensionScope.user.workspacePath == nil)
        #expect(ExtensionScope.workspace("/w").wireName == "workspace" && ExtensionScope.workspace("/w").workspacePath == "/w")
    }
}
