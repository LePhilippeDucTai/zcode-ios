import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SubagentsClientTests {
    private let host = "/Users/u/claude"

    private func connected(_ server: FakeZCodeServer) async -> ChannelClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return client
    }

    private func subagents(_ server: FakeZCodeServer) async -> SubagentsClient {
        SubagentsClient(client: await connected(server), hostWorkspace: host)
    }

    private func record(_ folder: String, _ prefix: String) throws -> JSONValue {
        try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
    }

    /// Agents réels du cycle de vie : Explore (intégré), un agent de projet, un agent utilisateur désactivé, un agent de
    /// plugin.
    private func realAgents() throws -> (explore: AgentSummary, project: AgentSummary, user: AgentSummary, plugin: AgentSummary) {
        let project = try AgentsListResult(json: try record("subagents-lifecycle", "005"))
        let user = try AgentsListResult(json: try record("subagents-lifecycle", "010"))
        return (
            try #require(project.agents.first { $0.name == "Explore" }),
            try #require(project.userAgents.first),
            try #require(user.userAgents.first),
            try #require(project.pluginAgents.first)
        )
    }

    @Test func listeUtilisateurEtProjet() async throws {
        let server = FakeZCodeServer()
        let list = try record("subagents-read", "001")
        await server.on("subagents.list") { _ in list }
        let client = await subagents(server)
        let result = try await client.list(scope: .user)
        #expect(result.agents.count == 2)
        _ = try await client.list(scope: .workspace("/w"))
        #expect(await server.calls(to: "subagents.list") == [
            .object(["workspacePath": .string(host), "provider": .string("glm"), "mode": .string("settingsUserOnly")]),
            .object(["workspacePath": .string("/w"), "provider": .string("glm"), "mode": .string("allRuntimeScopes")]),
        ])
    }

    @Test func creationDansLeProjet() async throws {
        let server = FakeZCodeServer()
        let created = try record("subagents-lifecycle", "008")
        await server.on("subagents.createAgent") { _ in created }
        let config = SubAgentConfig(name: "zcode-ios-probe-user", description: "d", systemPrompt: "s")
        let agent = try await subagents(server).create(config, scope: .workspace("/w"))
        #expect(agent.name == "zcode-ios-probe-user" && agent.path.hasSuffix(".md"))
        #expect(await server.calls(to: "subagents.createAgent") == [.object([
            "config": config.json, "provider": .string("glm"), "scope": .string("workspace"), "workspacePath": .string("/w"),
        ])])
    }

    @Test func creationUtilisateurSansChemin() async throws {
        let server = FakeZCodeServer()
        let created = try record("subagents-lifecycle", "008")
        await server.on("subagents.createAgent") { _ in created }
        let config = SubAgentConfig(name: "abc", description: "d", systemPrompt: "s")
        _ = try await subagents(server).create(config, scope: .user)
        #expect(await server.calls(to: "subagents.createAgent") == [.object([
            "config": config.json, "provider": .string("glm"), "scope": .string("user"),
        ])])
    }

    @Test func renommageAvecAncienChemin() async throws {
        let server = FakeZCodeServer()
        let updated = try record("subagents-lifecycle", "006")
        await server.on("subagents.updateAgent") { _ in updated }
        let agent = try realAgents().project
        var config = SubAgentConfig(agent)
        config.name = "zcode-ios-probe-agent-v2"
        let result = try await subagents(server).update(agent, with: config, scope: .workspace("/w"))
        #expect(result.id == "user:workspace:zcode-ios-probe-agent-v2")
        #expect(await server.calls(to: "subagents.updateAgent") == [.object([
            "agentId": .string(agent.id), "oldFilePath": .string(agent.path), "config": config.json,
            "provider": .string("glm"), "scope": .string("workspace"), "workspacePath": .string("/w"),
        ])])
    }

    @Test func suppressionParCheminLu() async throws {
        let server = FakeZCodeServer()
        await server.on("subagents.deleteAgent") { _ in .null }
        let agent = try realAgents().project
        try await subagents(server).delete(agent)
        #expect(await server.calls(to: "subagents.deleteAgent") == [.object([
            "agentId": .string(agent.id), "filePath": .string(agent.path),
        ])])
    }

    @Test func basculementDUnAgentUtilisateur() async throws {
        let server = FakeZCodeServer()
        await server.on("subagents.setEnabled") { _ in .null }
        let agent = try realAgents().user
        try await subagents(server).setEnabled(agent, true)
        #expect(await server.calls(to: "subagents.setEnabled") == [.object([
            "agentId": .string(agent.id), "enabled": .bool(true),
        ])])
    }

    @Test func agentEnLectureSeuleRefuseSansAppel() async throws {
        let server = FakeZCodeServer()
        let client = await subagents(server)
        let agents = try realAgents()
        let config = SubAgentConfig(agents.explore)
        await #expect(throws: SubagentsClientError.readOnly("Explore")) {
            try await client.update(agents.explore, with: config, scope: .user)
        }
        await #expect(throws: SubagentsClientError.readOnly("Explore")) { try await client.delete(agents.explore) }
        await #expect(throws: SubagentsClientError.readOnly("Explore")) { try await client.setEnabled(agents.explore, false) }
        // Un agent de plugin non plus ; un agent de projet n'a pas d'interrupteur.
        await #expect(throws: SubagentsClientError.self) { try await client.delete(agents.plugin) }
        await #expect(throws: SubagentsClientError.readOnly(agents.project.name)) {
            try await client.setEnabled(agents.project, false)
        }
        #expect(await server.callNames(prefix: "subagents.").isEmpty)
    }

    @Test func modeleDUnIntegreEtDUnPlugin() async throws {
        let server = FakeZCodeServer()
        await server.on("subagents.setBuiltInModelOverride") { _ in .null }
        await server.on("subagents.setPluginAgentModelOverride") { _ in .null }
        let client = await subagents(server)
        let agents = try realAgents()
        let selection = ModelSelection(providerId: "p", modelId: "m", reasoningLevel: "high")
        try await client.setModelOverride(agents.explore, selection)
        try await client.setModelOverride(agents.explore, nil)
        try await client.setModelOverride(agents.plugin, selection)
        #expect(await server.calls(to: "subagents.setBuiltInModelOverride") == [
            .object(["agentName": .string("Explore"), "modelSelection": try V4JSON.encode(selection)]),
            .object(["agentName": .string("Explore")]),
        ])
        #expect(await server.calls(to: "subagents.setPluginAgentModelOverride") == [.object([
            "agentId": .string(agents.plugin.id), "modelSelection": try V4JSON.encode(selection),
        ])])
        // Un agent personnalisé règle son modèle dans son formulaire : refusé sans appel.
        let before = await server.callNames(prefix: "subagents.").count
        await #expect(throws: SubagentsClientError.notOverridable(agents.user.name)) {
            try await client.setModelOverride(agents.user, selection)
        }
        #expect(await server.callNames(prefix: "subagents.").count == before)
    }

    @Test func modeleRetablitUnAgentDePlugin() async throws {
        let server = FakeZCodeServer()
        await server.on("subagents.setPluginAgentModelOverride") { _ in .null }
        let plugin = try realAgents().plugin
        try await subagents(server).setModelOverride(plugin, nil)
        #expect(await server.calls(to: "subagents.setPluginAgentModelOverride") == [.object(["agentId": .string(plugin.id)])])
    }

    @Test func erreurDeLHoteTransmise() async throws {
        let server = FakeZCodeServer()
        let message = "Agent file \"x.md\" already exists"
        await server.on("subagents.createAgent") { _ in throw FakeRemoteError(message) }
        let config = SubAgentConfig(name: "xyz", description: "d", systemPrompt: "s")
        do {
            _ = try await subagents(server).create(config, scope: .user)
            Issue.record("la création aurait dû échouer")
        } catch let RPCError.remote(error) {
            #expect(error.message == message)
        }
    }

    @Test func reponseIllisible() async throws {
        let server = FakeZCodeServer()
        await server.on("subagents.list") { _ in .string("?") }
        await server.on("subagents.createAgent") { _ in .object([:]) }
        let client = await subagents(server)
        await #expect(throws: AgentV4Error.self) { try await client.list(scope: .user) }
        do {
            _ = try await client.list(scope: .user)
        } catch let AgentV4Error.malformedResponse(method, _) {
            #expect(method == "subagents.list")
        }
        do {
            _ = try await client.create(SubAgentConfig(name: "xyz", description: "d", systemPrompt: "s"), scope: .user)
            Issue.record("une réponse sans agent aurait dû échouer")
        } catch let AgentV4Error.malformedResponse(method, _) {
            #expect(method == "subagents.createAgent")
        }
    }
}
