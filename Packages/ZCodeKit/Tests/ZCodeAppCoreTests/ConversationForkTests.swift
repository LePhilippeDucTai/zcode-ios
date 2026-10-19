import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Accusé réel de `forkAssistant` (`fork/009`), commande renvoyée à l'identique.
private func forkAck(_ argument: JSONValue) throws -> JSONValue {
    var ack = try #require(try Fixtures.record(in: "v3.15.1/fork", prefix: "009").objectValue)
    ack["commandId"] = argument["envelope"]?["commandId"] ?? .null
    return .object(ack)
}

@MainActor
struct ConversationForkTests {
    func readyModel(_ server: FakeZCodeServer) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame())       // PONG : ligne 4 `canFork`
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func envelopes(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func reponsesQuiPeuventServirDeDepart() async throws {
        let model = try await readyModel(try await conversationServer())
        #expect(model.forkableRowIds == [4])
    }

    @Test func forkOuvreLaSessionEnfant() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { try forkAck($0) }
        let model = try await readyModel(server)
        let child = await model.fork(rowId: 4)
        let expected = try Fixtures.record(in: "v3.15.1/fork", prefix: "009")["result"]?["sessionId"]?.stringValue
        #expect(child != nil && child == expected)
        let envelope = try #require(await envelopes(server).first)
        #expect(envelope["type"] == .string("forkAssistant"))
        #expect(envelope["payload"]?["target"]?["rowId"] == .number(4))
        #expect(envelope["payload"]?["target"]?["entityId"] == .string("msg_mv6i5rdq_805f0286-2479-4853-8b83-df66bd8b2f68"))
        #expect(envelope["baseRevision"] == .number(9) && envelope["baseLogEpoch"] == .string("mv6j6gf9-m0d4m1jc"))
    }

    @Test func doubleAppuiNEnvoieQuUnFork() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { try forkAck($0) }
        let model = try await readyModel(server)
        async let first = model.fork(rowId: 4)
        async let second = model.fork(rowId: 4)
        let results = await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(await envelopes(server).filter { $0["type"] == .string("forkAssistant") }.count == 1)
        #expect(await model.fork(rowId: 4) != nil)                           // la garde est levée à la fin
    }

    @Test func doublonAccepteCommeLeWeb() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("duplicate"),
                     "result": .object(["type": .string("forkAssistant"), "sessionId": .string("sess_enfant")])])
        }
        let model = try await readyModel(server)
        #expect(await model.fork(rowId: 4) == "sess_enfant")
    }

    @Test func forkPerimeReessaye() async throws {
        let server = try await conversationServer()
        let attempts = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            attempts.next() == 1
                ? .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("stale"),
                           "reasonCode": .string("proto.staleRevision"), "revisionAtDecision": .number(12)])
                : .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                           "result": .object(["type": .string("forkAssistant"), "sessionId": .string("sess_enfant")])])
        }
        let model = try await readyModel(server)
        #expect(await model.fork(rowId: 4) == "sess_enfant")
        #expect(await envelopes(server).map { $0["baseRevision"] } == [.number(9), .number(12)])
        #expect(model.commandError == nil)
    }

    @Test func forkRefuseSansNavigation() async throws {
        for (reason, message) in [
            ("proto.staleTarget", "Cette réponse a changé entre-temps : réessaie."),
            ("guard.compactOperationLock", "Une compression du contexte est en cours : réessaie quand elle sera finie."),
            ("guard.forkTargetNotStable", "Cette réponse n'est pas encore figée : attends la fin du tour."),
            ("guard.forkTargetAmbiguous", "Point de départ ambigu : choisis une autre réponse."),
            ("guard.forkAssistantOnly", "Seule une réponse de l'agent peut servir de point de départ."),
            ("guard.actionUnavailable", "Action indisponible pour l'instant (tour en cours ou demande en attente)."),
        ] {
            let server = try await conversationServer()
            await server.on("zcode-agent.sendConversationCommandV4") { interactionAck($0, "rejected", reasonCode: reason) }
            let model = try await readyModel(server)
            #expect(await model.fork(rowId: 4) == nil)
            #expect(model.commandError == message, "\(reason)")
        }
    }

    @Test func ligneNonEligibleSansAppel() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.fork(rowId: 2) == nil)                           // message de l'utilisateur
        #expect(await envelopes(server).isEmpty)
    }
}
