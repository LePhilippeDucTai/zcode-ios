import Foundation
import Testing
import ZCodeTestSupport
@testable import ZCodeV4
import ZCodeWire

struct SubagentDecodingTests {
    func subagentRow(_ fields: [String: JSONValue]) throws -> ConversationRow {
        var object: [String: JSONValue] = [
            "rowId": .number(7), "kind": .string("subagent"), "turnId": .string("t1"),
            "subagentType": .string("Explore"), "status": .string("success"), "summaryText": .string("Fini"),
        ]
        object.merge(fields) { _, new in new }
        return try #require(ConversationRow(json: .object(object)))
    }

    @Test func champsComplets() throws {
        let row = try subagentRow([
            "parentToolCallId": .string("call_1"), "childSessionId": .string("sess_subagent_agent_a"),
            "backgrounded": .bool(true), "startedAt": .number(1_000), "endedAt": .number(4_500),
        ])
        guard case .subagent(let value) = row.content else { Issue.record("sous-agent attendu"); return }
        #expect(value.parentToolCallId == "call_1")
        #expect(value.childSessionId == "sess_subagent_agent_a")
        #expect(value.backgrounded)
        #expect(value.startedAt == 1_000)
        #expect(value.endedAt == 4_500)
    }

    @Test func champsOptionnelsDeMauvaisType() throws {
        // Tolérant : la ligne reste un sous-agent, les champs illisibles valent nil / false.
        let row = try subagentRow([
            "parentToolCallId": .number(3), "childSessionId": .bool(true), "backgrounded": .string("oui"),
            "startedAt": .string("x"),
        ])
        guard case .subagent(let value) = row.content else { Issue.record("sous-agent attendu"); return }
        #expect(value.parentToolCallId == nil)
        #expect(value.childSessionId == nil)
        #expect(value.backgrounded == false)
        #expect(value.startedAt == nil)
        #expect(value.summaryText == "Fini")
    }

    @Test func deltaDuResumeGardeLesChamps() throws {
        let row = try subagentRow(["parentToolCallId": .string("call_1"), "startedAt": .number(1_000)])
        guard case .subagent(let value) = row.appending(" ici", at: .summaryText).content else {
            Issue.record("sous-agent attendu"); return
        }
        #expect(value.summaryText == "Fini ici")
        #expect(value.parentToolCallId == "call_1")
        #expect(value.startedAt == 1_000)
    }

    func snapshot(subagents: JSONValue) throws -> ConversationSnapshot {
        try ConversationSnapshot(json: .object([
            "sessionId": .string("s"), "logEpoch": .string("e"),
            "rows": .object(["window": .array([])]), "subagents": subagents,
        ]))
    }

    @Test func sousAgentsEnCours() throws {
        let value = try snapshot(subagents: .object([
            "revision": .number(2), "childSessionIds": .array([.string("c1"), .string("c2")]), "endedTotal": .number(0),
            "running": .array([
                .object(["childSessionId": .string("c1"), "agentId": .string("a1"), "toolCallId": .string("call_1"),
                         "subagentType": .string("Explore"), "title": .string("Lister"), "summary": .string("Lecture"),
                         "status": .string("running"), "startedAt": .number(1_000)]),
                .object(["childSessionId": .string("c2"), "subagentType": .string("Plan"), "title": .string("Plan"),
                         "status": .string("nouveau")]),
                .object(["subagentType": .string("sans enfant")]),             // sans childSessionId : ignoré
                .string("illisible"),
            ]),
        ]))
        #expect(value.runningSubagents.map(\.childSessionId) == ["c1", "c2"])
        #expect(value.runningSubagents[0].title == "Lister")
        #expect(value.runningSubagents[0].summary == "Lecture")
        #expect(value.runningSubagents[0].startedAt == 1_000)
        #expect(value.runningSubagents[1].status == "nouveau")                // statut inconnu gardé
        #expect(value.runningSubagents[1].startedAt == nil)
    }

    @Test func projectionAbsenteOuIllisible() throws {
        #expect(try snapshot(subagents: .null).runningSubagents.isEmpty)
        #expect(try snapshot(subagents: .object(["running": .object([:])])).runningSubagents.isEmpty)
    }

    @Test func projectionMiseAJourParDelta() throws {
        var value = try snapshot(subagents: .object(["running": .array([])]))
        value.apply(.stateUpdated(["subagents": .object(["running": .array([
            .object(["childSessionId": .string("c9"), "subagentType": .string("Explore"), "title": .string("T"),
                     "status": .string("blocked")]),
        ])])]))
        #expect(value.runningSubagents.map(\.childSessionId) == ["c9"])
    }

    @Test func ligneReelleDuParent() throws {
        // Fixture de la tâche 0 : la trame 004 (fenêtre du snapshot) et la page 005 sont celles du parent.
        let records = try Fixtures.records(in: "v3.15.1/subagent-thread")
            .filter { $0.file.hasPrefix("004") || $0.file.hasPrefix("005") }
        #expect(records.count == 2)
        let rows = records.flatMap { record -> [ConversationRow] in
            let window = record.value["frame"]?["payload"]?["snapshot"]?["rows"]?["window"]?.arrayValue
                ?? record.value["rows"]?.arrayValue ?? []
            return window.compactMap(ConversationRow.init(json:))
        }
        let subagents = rows.compactMap { row -> Subagent? in if case .subagent(let v) = row.content { v } else { nil } }
        #expect(!subagents.isEmpty)
        #expect(subagents.contains { $0.childSessionId?.isEmpty == false })
        #expect(subagents.contains { $0.parentToolCallId?.isEmpty == false && $0.startedAt != nil && $0.endedAt != nil })
    }
}

