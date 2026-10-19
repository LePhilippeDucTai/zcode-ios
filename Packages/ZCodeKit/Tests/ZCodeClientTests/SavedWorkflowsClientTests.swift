import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Fixtures réelles `list.project` / `list.global` du dossier `saved-workflows/trivial`.
enum SavedWorkflowsDecodingFixtures {
    static func value(_ name: String) throws -> JSONValue {
        try #require(try Fixtures.records(in: "v3.15.1/saved-workflows/trivial").first { $0.name == name }).value
    }
}

struct SavedWorkflowsClientTests {
    func connected(_ server: FakeZCodeServer) async -> ChannelClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return client
    }

    @Test func projetPuisGlobal() async throws {
        let server = FakeZCodeServer()
        let project = try SavedWorkflowsDecodingFixtures.value("list.project")
        let global = try SavedWorkflowsDecodingFixtures.value("list.global")
        await server.on("zcode-agent.listSavedWorkflows") { params in
            params["scope"]?.stringValue == "global" ? global : project
        }
        let client = SavedWorkflowsClient(client: await connected(server), workspacePath: "/w")
        #expect(try await client.project().workflows.contains { $0.name == "ios-probe" })
        #expect(try await client.global().workflows.allSatisfy { $0.scope == .global })
        let calls = await server.calls(to: "zcode-agent.listSavedWorkflows")
        #expect(calls.count == 2)
        #expect(calls[0]["workspacePath"] == .string("/w") && calls[0]["scope"] == nil)
        #expect(calls[1]["scope"] == .string("global") && calls[1]["workspacePath"] == nil)
    }

    @Test func reponseIllisible() async throws {
        let server = FakeZCodeServer()
        await server.on("zcode-agent.listSavedWorkflows") { _ in .string("non") }
        let client = SavedWorkflowsClient(client: await connected(server), workspacePath: "/w")
        await #expect(throws: AgentV4Error.self) { try await client.project() }
    }
}
