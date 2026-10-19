import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ComposerCatalogClientTests {
    func connected(_ server: FakeZCodeServer) async -> ChannelClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return client
    }

    @Test func troisLecturesCommeLeNavigateur() async throws {
        let server = FakeZCodeServer()
        let session = "\(ComposerCatalogClient.presentationChannel).readWorkspacePresentation"
        await server.on(session) { _ in
            .object(["mode": .string("build"), "slashCommands": .array([.object(["name": .string("goal"), "description": .string("Goal")])])])
        }
        await server.on("zcode-agent.getSkillReferenceCatalog") { _ in .object(["authority": .string("session"), "skills": .array([])]) }
        await server.on("coding-plan-subscription.getDynamicWorkflowClientConfig") { _ in
            .object(["mode": .string("onDemand"), "enabled": .bool(true), "source": .string("remote"), "offeredMode": .string("onDemand")])
        }
        let catalog = ComposerCatalogClient(client: await connected(server), workspacePath: "/w")
        #expect(try await catalog.presentation().slashCommands.map(\.name) == ["goal"])
        #expect(try await catalog.skills(sessionId: nil).skills.isEmpty)
        #expect(try await catalog.skills(sessionId: "sess_1").authority == "session")
        #expect(try await catalog.dynamicWorkflowConfig() == DynamicWorkflowConfig(json: .object([
            "mode": .string("onDemand"), "enabled": .bool(true), "source": .string("remote"), "offeredMode": .string("onDemand"),
        ])))
        // Un objet par appel, champ absent omis ; aucun argument pour la configuration des workflows.
        #expect(await server.calls(to: session) == [.object(["workspacePath": .string("/w")])])
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog") == [
            .object(["workspacePath": .string("/w")]),
            .object(["workspacePath": .string("/w"), "sessionId": .string("sess_1")]),
        ])
        #expect(await server.calls(to: "coding-plan-subscription.getDynamicWorkflowClientConfig") == [.null])
    }

    @Test func reponseIllisibleEtErreurDeLHote() async throws {
        let server = FakeZCodeServer()
        await server.on("\(ComposerCatalogClient.presentationChannel).readWorkspacePresentation") { _ in .string("?") }
        // Message réel de l'hôte (fixture slash/007).
        await server.on("zcode-agent.getSkillReferenceCatalog") { _ in
            throw FakeRemoteError("Session is not active: sess_zcode-probe-inexistante")
        }
        let catalog = ComposerCatalogClient(client: await connected(server), workspacePath: "/w")
        await #expect(throws: AgentV4Error.self) { try await catalog.presentation() }
        await #expect(throws: RPCError.self) { try await catalog.skills(sessionId: "sess_x") }
    }
}
