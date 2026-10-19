import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct FakeZCodeServerTests {
    func connected(_ server: FakeZCodeServer) async -> AgentV4 {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return AgentV4(client: client, workspacePath: testWorkspace)
    }

    @Test func repondParNomDeMethode() async throws {
        let server = FakeZCodeServer()
        let hello = try Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json")
        await server.on("zcode-agent.helloConversationV4") { _ in hello }
        await server.on("zcode-agent.initializeConversationV4") { _ in .null }
        let agent = await connected(server)
        #expect(try await agent.handshake(clientId: "client-x", appVersion: "test").protocolVersion == 3)
        let initialize = await server.calls(to: "zcode-agent.initializeConversationV4")
        #expect(initialize == [ClientHello(clientId: "client-x", appVersion: "test").json])
    }

    @Test func methodeNonSimuleeEnErreur() async throws {
        let server = FakeZCodeServer()
        let agent = await connected(server)
        do {
            _ = try await agent.rowsRange(sessionId: "s")
            Issue.record("une erreur était attendue")
        } catch RPCError.remote(let error) {
            #expect(error.message.contains("zcode-agent.conversationRowsRangeV4"))
        }
    }

    @Test func diffuseAuxEcoutesOuvertes() async throws {
        let server = FakeZCodeServer()
        let agent = await connected(server)
        let frames = try await agent.conversationFrames()
        _ = try await eventually { await server.listenerCount("zcode-agent.onDynamicConversationFrame") > 0 ? true : nil }
        await server.emit("zcode-agent.onDynamicConversationFrame", .object(["n": .number(1)]))
        var iterator = frames.makeAsyncIterator()
        #expect(await iterator.next() == .object(["n": .number(1)]))
    }
}
