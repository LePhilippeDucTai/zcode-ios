import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private func goalJSON(_ status: String) -> JSONValue {
    .object(["targetId": .string("tgt_01"), "objective": .string("tests verts"), "status": .string(status), "iteration": .number(1)])
}

/// Accusé d'un Goal : `accepted` sans `result` (vu en réel, fixture `goal/001`).
private func goalAck(_ argument: JSONValue) -> JSONValue {
    .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"), "revisionAtDecision": .number(9)])
}

@MainActor
struct ConversationGoalTests {
    func envelopes(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func goalTapeEnvoieLObjectifSeul() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { goalAck($0) }
        let model = try await readyConversation(server)
        #expect(await model.send("/goal tests verts") == .sent(delivery: nil))
        let envelope = try #require(await envelopes(server).first)
        #expect(envelope["type"] == .string("sendGoalCommand"))
        #expect(envelope["payload"]?["text"] == .string("tests verts"))
        #expect(envelope["payload"]?["displayText"] == .string("/goal tests verts"))
        #expect(envelope["payload"]?["mode"] == .string("build") && envelope["payload"]?["planEnabled"] == .bool(false))
        #expect(envelope["payload"]?["modelSelection"]?["modelId"] == .string("GLM-5.3"))
        #expect(model.commandError == nil)
    }

    @Test func variantesNonPrisesEnChargeSansAppel() async throws {
        let server = try await conversationServer()
        let model = try await readyConversation(server)
        #expect(await model.send("/goal pause") == .failed)
        #expect(model.commandError == "Mets le Goal en pause depuis le bandeau.")
        #expect(await model.send("/goal clear") == .failed)
        #expect(model.commandError == "ZCode ne permet pas d'effacer un Goal : mets-le en pause, ou lance un nouvel objectif.")
        #expect(await model.send("/goal") == .failed)
        #expect(model.commandError == "Écris l'objectif après /goal.")
        #expect(await model.startGoal(String(repeating: "x", count: 4_001)) == .failed)
        #expect(model.commandError == "Objectif trop long (4 000 caractères au plus).")
        #expect(await envelopes(server).isEmpty)
    }

    @Test func goalRefuseEnModePlan() async throws {
        let server = try await conversationServer()
        let model = try await readyConversation(server)
        model.selectMode("plan")
        #expect(await model.send("/goal tests verts") == .failed)
        #expect(model.commandError == "Le Goal est indisponible en mode plan : change de mode.")
        #expect(await envelopes(server).isEmpty)
    }

    @Test func goalAvecFileEnPause() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { goalAck($0) }
        let model = try await readyConversation(server) { $0["inputRouting"] = .object(["mode": .string("choice")]) }
        #expect(await model.send("/goal tests verts") == .needsQueueChoice(itemIds: []))
        #expect(await envelopes(server).isEmpty)
        let outcome = await model.send("/goal tests verts", heldQueue: .init(.clearQueueAndSend, expectedItemIds: []))
        #expect(outcome == .sent(delivery: nil))
        #expect(await envelopes(server).first?["payload"]?["heldQueueDisposition"] == .string("clearQueueAndSend"))
    }

    @Test func goalPendantUnTour() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { goalAck($0) }
        let model = try await readyConversation(server) {
            $0["inputRouting"] = .object(["mode": .string("enqueue")])
            $0["control"] = .object(["phase": .string("running"), "canStop": .bool(true), "activeWorks": .array([])])
        }
        #expect(await model.send("/goal tests verts") == .sent(delivery: nil))       // l'hôte le met en file
        #expect(await envelopes(server).first?["type"] == .string("sendGoalCommand"))
    }

    @Test func resumeTapeEnvoieResumeGoal() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { goalAck($0) }
        let model = try await readyConversation(server) {
            $0["goal"] = goalJSON("paused")
            $0["availability"] = .object(["resumeGoal": .object(["allowed": .bool(true)])])
        }
        #expect(model.goal?.status == .paused && model.canResumeGoal && !model.canPauseGoal)
        #expect(await model.send("/goal resume") == .sent(delivery: nil))
        let envelope = try #require(await envelopes(server).first)
        #expect(envelope["type"] == .string("resumeGoal"))
        #expect(envelope["baseRevision"] == .number(Double(try #require(model.snapshot).revision)))
    }

    @Test func pauseEtRepriseSelonDisponibilite() async throws {
        let server = try await conversationServer()
        let attempts = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            attempts.next() == 1
                ? .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("stale"),
                           "reasonCode": .string("proto.staleRevision"), "revisionAtDecision": .number(42)])
                : goalAck(argument)
        }
        let model = try await readyConversation(server) {
            $0["goal"] = goalJSON("active")
            $0["availability"] = .object(["pauseGoal": .object(["allowed": .bool(true)]),
                                          "resumeGoal": .object(["allowed": .bool(false), "reasonCode": .string("goalNotPaused")])])
        }
        #expect(model.canPauseGoal && !model.canResumeGoal)
        await model.pauseGoal()
        let sent = await envelopes(server)
        #expect(sent.map { $0["type"] } == [.string("pauseGoal"), .string("pauseGoal")])
        #expect(sent.last?["baseRevision"] == .number(42))
        #expect(model.commandError == nil)
    }

    @Test func refusDeLHoteTraduit() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, "failed", reasonCode: "activeTurn")
        }
        let model = try await readyConversation(server) {
            $0["goal"] = goalJSON("paused")
            $0["availability"] = .object(["resumeGoal": .object(["allowed": .bool(true)])])
        }
        await model.resumeGoal()
        #expect(model.commandError == "Attends la fin du tour en cours pour reprendre le Goal.")
    }

    @Test func verificationInterrompue() throws {
        func label(_ marker: [String: JSONValue]) throws -> String? {
            let row = try #require(ConversationRow(json: .object([
                "rowId": .number(6), "kind": .string("timelineMarker"), "lane": .string("turnTailBoundary"),
                "marker": .object(marker),
            ])))
            guard case .timelineMarker(let value) = row.content else { Issue.record("marqueur attendu"); return nil }
            return value.label
        }
        #expect(try label(["type": .string("goalVerify"), "iteration": .number(2), "outcome": .string("failed"),
                           "detail": .string("cancelled")]) == "Itération 2 · Vérification du Goal interrompue")
        #expect(try label(["type": .string("goalVerify"), "iteration": .number(1), "outcome": .string("pass")])
            == "Itération 1 · Goal atteint")
    }
}
