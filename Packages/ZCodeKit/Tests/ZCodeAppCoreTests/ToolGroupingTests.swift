import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ToolGroupingTests {
    // MARK: Aides

    func row(_ rowId: Int, _ kind: String, turn: String = "t1", _ fields: [String: JSONValue] = [:]) throws -> ConversationRow {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string(turn)
        return try #require(ConversationRow(json: .object(object)))
    }

    func toolRow(_ rowId: Int, turn: String = "t1", status: String = "success", name: String = "Bash",
                 approval: String? = nil, callId: String? = nil) throws -> ConversationRow {
        var fields: [String: JSONValue] = [
            "toolCallId": .string(callId ?? "c\(rowId)"), "toolName": .string(name), "status": .string(status), "inputText": .string("{}"),
        ]
        if let approval { fields["approvalInteractionId"] = .string(approval) }
        return try row(rowId, "toolCall", turn: turn, fields)
    }

    func reasoningRow(_ rowId: Int, turn: String = "t1", state: String = "complete") throws -> ConversationRow {
        try row(rowId, "reasoning", turn: turn, ["text": .string("hmm"), "state": .string(state)])
    }

    func textRow(_ rowId: Int, turn: String = "t1") throws -> ConversationRow {
        try row(rowId, "assistantText", turn: turn, ["text": .string("ok"), "state": .string("complete")])
    }

    func userRow(_ rowId: Int, turn: String = "t1") throws -> ConversationRow {
        try row(rowId, "userInput", turn: turn, ["text": .string("q")])
    }

    func group(_ entry: ChatEntry) -> ToolGroup? {
        if case .toolGroup(let group) = entry.content { group } else { nil }
    }

    /// Identifiants lisibles : `g(n)` pour l'entrée d'un groupe d'id `n`.
    func labels(_ entries: [ChatEntry]) -> [String] {
        entries.map { group($0).map { "g(\($0.id))" } ?? String($0.id) }
    }

    func grouped(_ rows: [ConversationRow], expanded: Set<Int> = [], pending: Set<String> = []) -> [ChatEntry] {
        ChatTimeline.grouping(ChatTimeline.entries(from: rows), expanded: expanded, pendingInteractionIds: pending)
    }

    // MARK: Règles

    @Test func deuxOutilsFormentUnGroupeReplié() throws {
        let result = try grouped([userRow(1), toolRow(2), toolRow(3), textRow(4)])
        #expect(labels(result) == ["1", "g(2)", "4"])
        let g = try #require(group(result[1]))
        #expect(!g.isExpanded)
        #expect(g.members.map(\.id) == [2, 3])
        #expect(result[1].id == g.entryId)
        #expect(result[1].fileChangesTarget == nil)
        #expect(result[1].messageTime == nil)
    }

    @Test func unSeulOutilNonGroupé() throws {
        let flat = try ChatTimeline.entries(from: [userRow(1), toolRow(2), textRow(3)])
        #expect(ChatTimeline.grouping(flat, expanded: [], pendingInteractionIds: []) == flat)
    }

    @Test func réflexionEtOutilFormentUnGroupe() throws {
        let result = try grouped([reasoningRow(1), toolRow(2), reasoningRow(3)])
        #expect(labels(result) == ["g(1)"])
        #expect(group(result[0])?.members.map(\.id) == [1, 2, 3])
    }

    @Test func texteCoupeLeGroupe() throws {
        let result = try grouped([toolRow(1), toolRow(2), textRow(3), toolRow(4), toolRow(5)])
        #expect(labels(result) == ["g(1)", "3", "g(4)"])
    }

    @Test func nouveauTourCoupeLeGroupe() throws {
        // L'outil 3 ouvre le tour b : il ne rejoint pas l'outil 2 du tour a.
        let none = try grouped([toolRow(2, turn: "a"), toolRow(3, turn: "b")])
        #expect(labels(none) == ["2", "3"])
        // Les deux suivants, du même tour b, forment un groupe qui porte le `startsTurn` de son premier membre.
        let result = try grouped([toolRow(1, turn: "a"), toolRow(2, turn: "b"), toolRow(3, turn: "b")])
        #expect(labels(result) == ["1", "g(2)"])
        #expect(result.map(\.startsTurn) == [true, true])
    }

    @Test func piedEtCarteDeWorkflowCoupent() throws {
        let tools = try ChatTimeline.entries(from: [toolRow(1), toolRow(2), toolRow(3), toolRow(4), toolRow(5)])
        // Pied d'un autre tour glissé entre les outils 2 et 3.
        let footer = try #require(ChatTimeline.entries(from: [
            row(9, "turnHeader", turn: "z", ["state": .string("completedSuccess")]), userRow(10, turn: "z"),
        ]).last)
        guard case .turnFooter = footer.content else { Issue.record("pied attendu"); return }
        let withFooter = Array(tools[0...1]) + [footer] + Array(tools[2...4])
        #expect(labels(ChatTimeline.grouping(withFooter, expanded: [], pendingInteractionIds: [])) == ["g(1)", "9", "g(3)"])

        // Carte de workflow placée après l'outil 2.
        let run = try #require(WorkflowRun(json: .object(["runId": .string("r"), "status": .string("running")])))
        let work = try V4JSON.decode(BackgroundWork.self, from: .object([
            "workId": .string("r"), "kind": .string("workflow"), "status": .string("running"), "anchorRowId": .number(2),
        ]))
        let card = try #require(WorkflowRunCard.cards(runs: [run], works: [work], rows: [], locked: false).first)
        let withCard = ChatTimeline.inserting([card], into: tools)
        let result = ChatTimeline.grouping(withCard, expanded: [], pendingInteractionIds: [])
        #expect(result.count == 3)
        #expect(labels(result).first == "g(1)")
        #expect(labels(result).last == "g(3)")
        #expect(result.contains { if case .workflowRun = $0.content { true } else { false } })
    }

    @Test func membresToujoursVisibles() throws {
        let rows = try [
            toolRow(1), toolRow(2, status: "running"), toolRow(3, status: "error"),
            toolRow(4, name: "Agent", callId: "agent"),
            row(5, "subagent", ["subagentType": .string("Explore"), "status": .string("running"), "summaryText": .string(""),
                                "parentToolCallId": .string("agent")]),
        ]
        let result = grouped(rows)
        #expect(labels(result) == ["g(1)", "2", "3", "4"])
        #expect(result.map(\.startsTurn) == [true, false, false, false])
        #expect(try #require(group(result[0])).members.map(\.id) == [1, 2, 3, 4])
    }

    @Test func statutsEnAttenteEtFlux() throws {
        let result = try grouped([toolRow(1), toolRow(2, status: "inputStreaming"), toolRow(3, status: "pendingApproval"),
                                  toolRow(4, status: "cancelled")])
        #expect(labels(result) == ["g(1)", "2", "3"])
    }

    @Test func réflexionEnFluxResteVisible() throws {
        let rows = try [toolRow(1), reasoningRow(2), toolRow(3), reasoningRow(4, state: "streaming")]
        #expect(labels(grouped(rows)) == ["g(1)", "4"])
        let entries = ChatTimeline.entries(from: rows)
        #expect(ChatTimeline.staysVisible(entries[3], pendingInteractionIds: []))
        #expect(!ChatTimeline.staysVisible(entries[1], pendingInteractionIds: []))
    }

    @Test func demandeOuverte() throws {
        let rows = try [toolRow(1), toolRow(2, approval: "i1"), toolRow(3, approval: "i2")]
        #expect(labels(grouped(rows, pending: ["i1"])) == ["g(1)", "2"])
        #expect(labels(grouped(rows, pending: [])) == ["g(1)"])
    }

    @Test func staysVisibleParType() throws {
        let entries = try ChatTimeline.entries(from: [toolRow(1), toolRow(2, status: "error"), reasoningRow(3), textRow(4)])
        #expect(!ChatTimeline.staysVisible(entries[0], pendingInteractionIds: []))
        #expect(ChatTimeline.staysVisible(entries[1], pendingInteractionIds: []))
        #expect(!ChatTimeline.staysVisible(entries[2], pendingInteractionIds: []))
        #expect(!ChatTimeline.staysVisible(entries[3], pendingInteractionIds: []))
    }

    @Test func dépliéMontreTout() throws {
        let result = try grouped([toolRow(1), toolRow(2), toolRow(3, status: "error"), textRow(4)], expanded: [1])
        #expect(labels(result) == ["g(1)", "1", "2", "3", "4"])
        #expect(try #require(group(result[0])).isExpanded)
        #expect(result.map(\.startsTurn) == [true, false, false, false, false])
        // Un autre groupe reste replié.
        let other = try grouped([toolRow(1), toolRow(2)], expanded: [7])
        #expect(labels(other) == ["g(1)"])
    }

    @Test func toutVisibleSansDoublon() throws {
        let result = try grouped([toolRow(1, status: "error"), toolRow(2, status: "error")])
        #expect(labels(result) == ["g(1)", "1", "2"])
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func identifiantsDistincts() throws {
        let result = try grouped([userRow(1), toolRow(2), toolRow(3), textRow(4), row(9, "turnHeader", ["state": .string("completedSuccess")])])
        let g = try #require(result.compactMap(group).first)
        #expect(g.entryId < -(1 << 32))
        #expect(Set(result.map(\.id)).count == result.count)
        #expect(result.filter { group($0) == nil }.allSatisfy { $0.id != g.entryId })
    }

    @Test func groupeContenant() throws {
        let flat = try ChatTimeline.entries(from: [toolRow(1), toolRow(2), toolRow(3), textRow(4), toolRow(5)])
        #expect(ChatTimeline.toolGroupId(containing: 3, in: flat) == 1)
        #expect(ChatTimeline.toolGroupId(containing: 1, in: flat) == 1)
        #expect(ChatTimeline.toolGroupId(containing: 4, in: flat) == nil)       // texte
        #expect(ChatTimeline.toolGroupId(containing: 5, in: flat) == nil)       // outil seul
        #expect(ChatTimeline.toolGroupId(containing: 99, in: flat) == nil)      // absent
    }

    // MARK: Conversations réelles

    /// Lignes d'une fixture : snapshot ou page de lignes, puis deltas `row.appended` / `row.upserted` (le dernier gagne).
    func fixtureRows(_ folder: String) throws -> [ConversationRow] {
        var byId: [Int: ConversationRow] = [:]
        for record in try Fixtures.records(in: folder) {
            let window = record.value["frame"]?["payload"]?["snapshot"]?["rows"]?["window"]?.arrayValue
                ?? record.value["rows"]?.arrayValue ?? []
            let deltas = (record.value["frame"]?["payload"]?["deltas"]?.arrayValue ?? []).compactMap { $0["row"] }
            for json in window + deltas {
                if let row = ConversationRow(json: json) { byId[row.rowId] = row }
            }
        }
        return byId.values.sorted { $0.rowId < $1.rowId }
    }

    func assertNothingLost(_ folder: String) throws -> Int {
        let flat = ChatTimeline.entries(from: try fixtureRows(folder))
        let cards = flat.filter { entry in
            if case .item(.tool) = entry.content { true } else if case .item(.reasoning) = entry.content { true } else { false }
        }.map(\.id)
        let result = ChatTimeline.grouping(flat, expanded: [], pendingInteractionIds: [])
        let members = result.compactMap(group).flatMap(\.members).map(\.id)
        let singles = result.filter { group($0) == nil }.map(\.id)
        // Chaque outil et réflexion du plat est soit membre d'un groupe, soit resté seul.
        #expect(Set(cards).isSubset(of: Set(members).union(singles)))
        #expect(Set(members).isDisjoint(with: Set(flat.filter { group($0) == nil }.map(\.id)).subtracting(cards)))
        #expect(Set(result.map(\.id)).count == result.count)
        // Les entrées qui ne sont ni outil ni réflexion sont inchangées et dans l'ordre.
        let others = flat.filter { !cards.contains($0.id) }
        #expect(result.filter { group($0) == nil && !cards.contains($0.id) } == others)
        return result.compactMap(group).count
    }

    @Test func fixtureRéelle() throws {
        let sendText = try assertNothingLost("v3.15.1/send-text")
        let thread = try assertNothingLost("v3.15.1/subagent-thread")
        #expect(sendText >= 1)
        #expect(thread >= 1)
    }
}
