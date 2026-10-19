import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationFeedbackTests {
    func control(_ phase: String, canStop: Bool) -> JSONValue {
        .object(["phase": .string(phase), "canStop": .bool(canStop), "activeWorks": .array([])])
    }

    func controlPatch(_ phase: String, canStop: Bool, revision: Int) -> JSONValue {
        .object(["op": .string("state.updated"), "patch": .object([
            "control": control(phase, canStop: canStop), "revision": .number(Double(revision)),
        ])])
    }

    /// Conversation PONG prête, tour en cours (`canStop`) et demandes `pending` en attente.
    func runningModel(_ server: FakeZCodeServer, pending: [String] = []) async throws -> ConversationModel {
        let interactions = try pending.map(syntheticInteraction)
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame {
            $0["control"] = self.control("running", canStop: true)
            $0["pendingInteractions"] = .array(interactions)
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func finDeTourReussie() async throws {
        let server = try await conversationServer()
        let model = try await runningModel(server)
        #expect(model.finishedTurns == 0)
        await server.emit(conversationEvent, try conversationDeltas([controlPatch("completedSuccess", canStop: false, revision: 10)]))
        _ = try await eventually { model.finishedTurns == 1 ? true : nil }
    }

    @Test func finDeTourEnErreurSansVibration() async throws {
        let server = try await conversationServer()
        let model = try await runningModel(server)
        await server.emit(conversationEvent, try conversationDeltas([controlPatch("error", canStop: false, revision: 10)]))
        _ = try await eventually { model.canStop == false ? true : nil }
        #expect(model.finishedTurns == 0)
    }

    @Test func nouvelleDemande() async throws {
        let server = try await conversationServer()
        let model = try await runningModel(server)
        await server.emit(conversationEvent, try conversationDeltas([pendingPatch([try syntheticInteraction("perm_bash")])]))
        _ = try await eventually { model.newInteractionAlerts == 1 ? true : nil }
        // Même demande republiée avec une autre : une seule alerte de plus.
        let both = [try syntheticInteraction("perm_bash"), try syntheticInteraction("ask_style")]
        await server.emit(conversationEvent, try conversationDeltas([pendingPatch(both, revision: 11)], fromSeq: 14, ordinal: 3))
        _ = try await eventually { model.newInteractionAlerts == 2 ? true : nil }
    }

    @Test func premierEtatSansVibration() async throws {
        let server = try await conversationServer()
        let model = try await runningModel(server, pending: ["perm_bash"])        // demande déjà là à l'ouverture
        #expect(model.newInteractionAlerts == 0)
        #expect(model.finishedTurns == 0)
    }
}
