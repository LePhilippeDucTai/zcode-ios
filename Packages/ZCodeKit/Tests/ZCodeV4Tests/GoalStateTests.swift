import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Goal non atteint après une itération (forme relevée dans `product-projection.ts`, ZCode 3.15.1).
let notSatisfiedGoalJSON: JSONValue = .object([
    "targetId": .string("tgt_01"), "objective": .string("Faire passer tous les tests"), "summaryTitle": .string("Tests verts"),
    "timeUsedSeconds": .number(55), "activeRunStartedAtMs": .null, "status": .string("notSatisfied"), "iteration": .number(1),
    "verifications": .array([.object([
        "iteration": .number(1), "outcome": .string("notSatisfied"), "at": .number(1_760_700_055_000), "anchorRowId": .number(37),
        "reason": .string("2 tests échouent encore dans billing.spec"), "nextAction": .string("Corriger billing.spec"),
    ])]),
    "iterations": .array([.object([
        "iteration": .number(1), "updatedAt": .number(1_760_700_040_000),
        "items": .array([.object(["id": .string("t1"), "content": .string("Corriger auth.spec"), "status": .string("completed")])]),
    ])]),
])

struct GoalStateTests {
    @Test func goalComplet() throws {
        let goal = try V4JSON.decode(GoalState.self, from: notSatisfiedGoalJSON)
        #expect(goal.targetId == "tgt_01" && goal.status == .notSatisfied && goal.iteration == 1)
        #expect(goal.verifications.first?.nextAction == "Corriger billing.spec")
        #expect(goal.verifications.first?.outcome == .notSatisfied && goal.verifications.first?.anchorRowId == 37)
        #expect(goal.verifications.first?.at == 1_760_700_055_000)
        #expect(goal.iterations.first?.items.first?.isCompleted == true)
        #expect(goal.activeRunStartedAtMs == nil && goal.summaryTitle == "Tests verts" && goal.timeUsedSeconds == 55)
    }

    @Test func goalTolerant() throws {
        let minimal = try V4JSON.decode(GoalState.self, from: .object(["objective": .string("x"), "status": .string("budgetLimited")]))
        #expect(minimal.status.rawValue == "budgetLimited" && minimal.iteration == 0 && minimal.verifications.isEmpty)
        #expect(minimal.iterations.isEmpty && minimal.timeUsedSeconds == 0 && minimal.summaryTitle == nil && minimal.targetId.isEmpty)
        let unknownOutcome = try V4JSON.decode(GoalVerification.self, from: .object([
            "iteration": .number(2), "outcome": .string("nouveau"), "at": .number(1),
        ]))
        #expect(unknownOutcome.outcome.rawValue == "nouveau" && unknownOutcome.anchorRowId == nil)

        // Dans un snapshot : `goal` illisible → nil, le snapshot reste lisible ; un vrai Goal est lu.
        var json = try #require(snapshotJSON(record("send-text", "004"))?.objectValue)
        json["goal"] = .object(["status": .number(3)])
        #expect(try ConversationSnapshot(json: .object(json)).goal == nil)
        json["goal"] = notSatisfiedGoalJSON
        #expect(try ConversationSnapshot(json: .object(json)).goal?.iteration == 1)
    }

    /// États réels d'une boucle (`zcode-probe goal`, ZCode 3.15.1) : null → active → active (titre généré) →
    /// verifying → verified.
    @Test func etatsReelsDUneBoucle() throws {
        let records = try Fixtures.records(in: "v3.15.1/goal")
        let goals = try records.filter { $0.file.hasSuffix("-goal.json") && $0.value != .null }
            .map { try V4JSON.decode(GoalState.self, from: $0.value) }
        #expect(goals.map(\.status) == [.active, .active, .verifying, .verified])
        #expect(goals.first?.iteration == 0 && goals.first?.activeRunStartedAtMs != nil && goals.first?.summaryTitle == nil)
        #expect(goals[1].summaryTitle == "Demande de réponse OK")
        #expect(goals.last?.iteration == 1 && goals.last?.verifications.last?.outcome == .pass)
        #expect(goals.last?.verifications.last?.anchorRowId == 6 && goals.last?.verifications.last?.reason?.isEmpty == false)
        #expect(goals.allSatisfy { $0.objective.hasPrefix("Réponds uniquement par le mot OK.") })
        let markers = records.filter { $0.file.hasSuffix("-marker.json") }.compactMap { $0.value["marker"] }
        #expect(markers.map { $0["outcome"]?.stringValue } == ["running", "pass"])
        let ack = try #require(records.first { $0.file.hasSuffix("-ack.json") }?.value)
        #expect(ack["status"] == .string("accepted") && ack["hasResult"] == .bool(false))
    }
}
