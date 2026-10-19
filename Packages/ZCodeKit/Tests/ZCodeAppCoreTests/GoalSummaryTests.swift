import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

private func goal(_ fields: [String: JSONValue]) throws -> GoalState {
    var object: [String: JSONValue] = ["objective": .string("Faire passer tous les tests"), "status": .string("active")]
    object.merge(fields) { $1 }
    return try V4JSON.decode(GoalState.self, from: .object(object))
}

private func verification(_ iteration: Int, _ outcome: String, next: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["iteration": .number(Double(iteration)), "outcome": .string(outcome), "at": .number(1)]
    if let next { object["nextAction"] = .string(next) }
    return .object(object)
}

struct GoalSummaryTests {
    @Test func resumeDUnGoalNonAtteint() throws {
        let summary = GoalSummary(try goal([
            "summaryTitle": .string("Tests verts"), "status": .string("notSatisfied"), "iteration": .number(1),
            "verifications": .array([verification(1, "notSatisfied", next: "Corriger billing.spec")]),
            "iterations": .array([.object(["iteration": .number(1), "items": .array([
                .object(["id": .string("t1"), "content": .string("Corriger auth.spec"), "status": .string("completed")]),
            ])])]),
        ]))
        #expect(summary.title == "Tests verts" && summary.statusLabel == "Non atteint, l'agent continue")
        #expect(summary.iterationLabel == "Itération 2" && !summary.isRunning)          // la continuation (2e) est ouverte
        #expect(summary.iterations.map(\.title) == ["Tests verts", "Corriger billing.spec"])
        #expect(summary.iterations[0].todosDone == 1 && summary.iterations[0].todosTotal == 1)
        #expect(summary.iterations.map(\.isCurrent) == [false, true])
    }

    @Test func dureeEnDirectEtJamaisNegative() throws {
        let running = GoalSummary(try goal(["timeUsedSeconds": .number(40), "activeRunStartedAtMs": .number(1_760_700_000_000)]))
        let t0 = Date(timeIntervalSince1970: 1_760_700_000)
        #expect(running.isRunning && running.iterationLabel == "Itération 1")         // 1re course : iteration vaut encore 0
        #expect(running.elapsedSeconds(at: t0.addingTimeInterval(5)) == 45)
        #expect(running.elapsedSeconds(at: t0.addingTimeInterval(-30)) == 40)          // horloges décalées
        #expect(GoalSummary(try goal(["timeUsedSeconds": .number(6)])).elapsedSeconds(at: t0) == 6)
        #expect(GoalSummary.durationLabel(42) == "42 s" && GoalSummary.durationLabel(185) == "3 min 05 s")
        #expect(GoalSummary.durationLabel(3_720) == "1 h 02 min" && GoalSummary.durationLabel(0) == "0 s")
    }

    @Test func titresDesIterations() throws {
        let verified = GoalSummary(try goal([
            "status": .string("verified"), "iteration": .number(2),
            "verifications": .array([verification(1, "notSatisfied", next: "Continue verifying and completing the goal."),
                                     verification(2, "pass")]),
        ]))
        #expect(verified.iterations.map(\.title) == ["Faire passer tous les tests", "Itération 2"])
        #expect(verified.iterations.allSatisfy { !$0.isCurrent } && verified.statusLabel == "Atteint")
        #expect(verified.verifications.map(\.iteration) == [2, 1])                    // plus récente d'abord

        let long = String(repeating: "a", count: 120) + "\nseconde ligne"
        let untitled = GoalSummary(try goal(["objective": .string(long), "status": .string("budgetLimited")]))
        #expect(untitled.title.count == 80 && !untitled.title.contains("\n"))
        #expect(untitled.statusLabel == "budgetLimited" && untitled.iterations.count == 1)
        let paused = GoalSummary(try goal(["status": .string("paused"), "iteration": .number(1)]))
        #expect(paused.statusLabel == "En pause" && paused.iterations.allSatisfy { !$0.isCurrent })   // rien ne tourne
        #expect(verified.iterationLabel == "Itération 2")
        // Une même itération peut porter deux conclusions (échec du vérificateur puis validation par défaut).
        let twice = GoalSummary(try goal(["status": .string("verified"), "iteration": .number(1),
                                          "verifications": .array([verification(1, "failed"), verification(1, "pass")])]))
        #expect(Set(twice.verificationEntries.map(\.id)).count == 2)
        #expect(GoalSummary(try goal(["status": .string("verifying")])).statusLabel == "Vérification…")
        #expect(GoalSummary(try goal(["status": .string("failed")])).statusLabel == "Vérification impossible")
    }
}
