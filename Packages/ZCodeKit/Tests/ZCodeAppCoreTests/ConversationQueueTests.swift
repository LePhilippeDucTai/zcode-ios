import Foundation
import Observation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

func queueItemJSON(_ id: String, admitted: String = "queue", state: String = "queued") -> JSONValue {
    .object([
        "queueItemId": .string(id), "kind": .string("sendText"), "text": .string("message \(id)"),
        "delivery": .object(["requested": .string("auto"), "admitted": .string(admitted)]),
        "dispatch": .object(["state": .string(state)]), "attachments": .array([]),
    ])
}

/// Session arrêtée avec une file en pause : q1 en file, q2 qui devait guider, q3 déjà prise en charge.
func pausedQueueFrame() throws -> JSONValue {
    try initialConversationFrame { snapshot in
        snapshot["inputRouting"] = .object(["mode": .string("choice"), "reasonCode": .string("heldQueueInputRequiresChoice")])
        snapshot["queue"] = .object([
            "autoDrain": .bool(false), "pauseReason": .string("stopped"),
            "items": .array([queueItemJSON("q1"), queueItemJSON("q2", admitted: "guide"), queueItemJSON("q3", state: "promoting")]),
        ])
    }
}

@MainActor
struct ConversationQueueTests {
    func readyModel(_ server: FakeZCodeServer, frame: JSONValue) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, frame)
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func fileEnPauseDemandeUnChoix() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, frame: pausedQueueFrame())
        #expect(model.queuedItems.map(\.queueItemId) == ["q1", "q3"])
        #expect(model.guideItems.map(\.queueItemId) == ["q2"])
        #expect(model.queuePaused)
        #expect(ChatLabels.queuePause(reason: "stopped") == "File en pause : tu as arrêté la réponse en cours.")
        #expect(await model.send("on reprend") == .needsQueueChoice(itemIds: ["q1", "q2", "q3"]))
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)   // rien envoyé sans choix
        let outcome = await model.send("on reprend", heldQueue: .init(.clearQueueAndSend, expectedItemIds: ["q1", "q2", "q3"]))
        #expect(outcome == .sent(delivery: "startNow"))
        let payload = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"]?["payload"])
        #expect(payload["heldQueueDisposition"] == .string("clearQueueAndSend"))
        #expect(payload["expectedHeldQueueItemIds"] == .array([.string("q1"), .string("q2"), .string("q3")]))
    }

    @Test func confirmationPerimeeRedemandee() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("failed"),
                "reasonCode": .string("guard.heldQueueConfirmationStale"), "revisionAtDecision": .number(10),
            ])
        }
        let model = try await readyModel(server, frame: pausedQueueFrame())
        let outcome = await model.send("on reprend", heldQueue: .init(.keepQueueAndSend, expectedItemIds: ["q1"]))
        #expect(outcome == .needsQueueChoice(itemIds: ["q1", "q2", "q3"]))
        #expect(model.commandError == nil)
    }

    @Test func commandeDeFileRenvoyeeSiPerimee() async throws {
        let server = try await conversationServer()
        let attempts = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            let stale = attempts.next() == 1
            return .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null,
                "status": .string(stale ? "stale" : "accepted"), "revisionAtDecision": .number(12),
            ])
        }
        let model = try await readyModel(server, frame: pausedQueueFrame())
        await model.deleteQueued("q1")
        let calls = await server.calls(to: "zcode-agent.sendConversationCommandV4")
        #expect(calls.count == 2)
        #expect(calls.map { $0["envelope"]?["baseRevision"] } == [.number(9), .number(12)])
        #expect(calls.last?["envelope"]?["type"] == .string("deleteQueueItem"))
        #expect(model.commandError == nil)
    }

    @Test func essaisIntermediairesPerimesSansBandeau() async throws {
        let server = try await conversationServer()
        let attempts = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            let stale = attempts.next() <= 2
            return .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null,
                "status": .string(stale ? "stale" : "accepted"), "revisionAtDecision": .number(12),
                "reasonCode": .string("proto.staleRevision"),
            ])
        }
        let model = try await readyModel(server, frame: pausedQueueFrame())
        let changes = Recorder<Bool>()
        withObservationTracking({ _ = model.commandError }, onChange: { changes.append(true) })
        await model.deleteQueued("q1")
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").count == 3)
        #expect(changes.all.isEmpty)                                           // aucun refus affiché pendant les essais
        #expect(model.commandError == nil)
    }

    @Test func commandePerimeeTroisFoisAffichee() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("stale"),
                "revisionAtDecision": .number(12), "reasonCode": .string("proto.staleRevision"),
            ])
        }
        let model = try await readyModel(server, frame: pausedQueueFrame())
        await model.deleteQueued("q1")
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").count == 3)
        #expect(model.commandError == "La conversation a changé entre-temps : réessaie.")
    }

    @Test func reprendreLaFile() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, frame: pausedQueueFrame())
        await model.resumeQueue()
        let envelope = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"])
        #expect(envelope["type"] == .string("setAutoDrain"))
        #expect(envelope["payload"] == .object(["autoDrain": .bool(true)]))
        #expect(model.canSendQueuedNow == false)                 // session arrêtée : « guider maintenant » indisponible
    }
}
