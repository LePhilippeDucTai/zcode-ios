import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ModelSelectionClientTests {
    func connected(_ server: FakeZCodeServer) async -> ModelSelectionClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return ModelSelectionClient(client: client)
    }

    @Test func lectureEtChangements() async throws {
        let server = FakeZCodeServer()
        let view = try Fixtures.file("synthetic/model-selection-mistral.json")
        await server.on("model-selection.getView") { _ in view }
        let client = await connected(server)
        #expect(try await client.getView().revision == 4)
        let selection = ModelSelection(providerId: "new-provider", modelId: "mistral-large-4", reasoningLevel: "none")
        _ = try await client.getView(selection: selection)
        let calls = await server.calls(to: "model-selection.getView")
        #expect(calls.first == .object(["selection": .null]))
        #expect(calls.last?["selection"]?["modelId"] == .string("mistral-large-4"))

        var changes = try await client.changes().makeAsyncIterator()
        _ = try await eventually { await server.listenerCount("model-selection.onDidChange") == 1 ? true : nil }
        await server.emit("model-selection.onDidChange", view)
        #expect(await changes.next() != nil)
    }

    @Test func reponseIllisible() async throws {
        let server = FakeZCodeServer()
        await server.on("model-selection.getView") { _ in .string("?") }
        let client = await connected(server)
        await #expect(throws: AgentV4Error.self) { try await client.getView() }
    }
}
