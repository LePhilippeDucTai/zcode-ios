import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationRetryTests {
    /// Trame réelle `send-text/004` : la ligne 4 (`assistantText`) porte `actions.canRetry`.
    func readyModel(_ server: FakeZCodeServer, retryable: Bool = true) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame { snapshot in
            guard !retryable, case .object(var rows)? = snapshot["rows"], case .array(let window)? = rows["window"] else { return }
            rows["window"] = .array(window.map { row in
                guard case .object(var object) = row else { return row }
                object["actions"] = nil
                return .object(object)
            })
            snapshot["rows"] = .object(rows)
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func envelopes(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func seuleLaReponseMarqueeEstRelancable() async throws {
        let marked = try await readyModel(try await conversationServer())
        #expect(marked.retryEntryId == 4)
        let unmarked = try await readyModel(try await conversationServer(), retryable: false)
        #expect(unmarked.retryEntryId == nil)
    }

    @Test func relancerEnvoieRetryTurnALaRevisionAffichee() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        await model.retryLastResponse()
        let envelope = try #require(await envelopes(server).first)
        let snapshot = try #require(model.snapshot)
        #expect(envelope["type"] == .string("retryTurn"))
        #expect(envelope["baseRevision"] == .number(Double(snapshot.revision)))
        #expect(envelope["payload"] == .object(["target": .object([
            "rowId": .number(4), "entityId": .string("msg_mv6i5rdq_805f0286-2479-4853-8b83-df66bd8b2f68"),
        ])]))
        #expect(model.commandError == nil)
    }

    @Test func relanceRefuseeAfficheUnMessage() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, "rejected", reasonCode: "guard.latestAssistantRetryOnly")
        }
        let model = try await readyModel(server)
        await model.retryLastResponse()
        #expect(model.commandError == "Seule la dernière réponse peut être relancée.")
    }

    @Test func rienARelancer() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, retryable: false)
        await model.retryLastResponse()
        #expect(await envelopes(server).isEmpty)
    }
}
