import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SubagentLinkTests {
    func row(_ rowId: Int, _ kind: String, turn: String = "t1", _ fields: [String: JSONValue]) throws -> ConversationRow {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string(turn)
        return try #require(ConversationRow(json: .object(object)))
    }

    func agent(_ rowId: Int, call: String, turn: String = "t1", name: String = "Agent",
               input: [String: JSONValue] = ["description": .string("Lister les fichiers"), "subagent_type": .string("Explore")],
               extra: [String: JSONValue] = [:]) throws -> ConversationRow {
        var fields: [String: JSONValue] = [
            "toolCallId": .string(call), "toolName": .string(name), "status": .string("success"),
            "inputText": .string(""), "input": .object(input),
        ]
        fields.merge(extra) { _, new in new }
        return try row(rowId, "toolCall", turn: turn, fields)
    }

    func subagent(_ rowId: Int, parent: String?, child: String?, turn: String = "t1", type: String = "Explore",
                  status: String = "success") throws -> ConversationRow {
        var fields: [String: JSONValue] = [
            "subagentType": .string(type), "status": .string(status), "summaryText": .string("Résumé \(rowId)"),
        ]
        if let parent { fields["parentToolCallId"] = .string(parent) }
        if let child { fields["childSessionId"] = .string(child) }
        return try row(rowId, "subagent", turn: turn, fields)
    }

    /// (rowId de la carte, enfant associé) pour chaque carte d'outil ; lignes `subagent` restées seules.
    func cards(_ rows: [ConversationRow]) -> (tools: [Int: String?], loose: [Int]) {
        var tools: [Int: String?] = [:]
        var loose: [Int] = []
        for entry in ChatTimeline.entries(from: rows) {
            guard case .item(let item) = entry.content else { continue }
            switch item {
            case .tool(let id, _, let link): tools[id] = link?.childSessionId
            case .subagent(let id, _): loose.append(id)
            default: break
            }
        }
        return (tools, loose)
    }

    @Test func associationParIdentifiant() throws {
        let result = cards(try [agent(2, call: "call_a"), subagent(3, parent: "call_a", child: "c_a")])
        #expect(result.tools[2] == "c_a")
        #expect(result.loose.isEmpty)                                // ligne associée : plus affichée à part
    }

    @Test func sousAgentsConcurrentsCroises() throws {
        // Les lignes `subagent` arrivent dans l'ordre inverse des appels : l'identifiant décide, pas l'ordre.
        let result = cards(try [
            agent(2, call: "call_a"), agent(3, call: "call_b"),
            subagent(4, parent: "call_b", child: "c_b"), subagent(5, parent: "call_a", child: "c_a"),
        ])
        #expect(result.tools[2] == "c_a")
        #expect(result.tools[3] == "c_b")
        #expect(result.loose.isEmpty)
    }

    @Test func autreTourJamaisAssocie() throws {
        let result = cards(try [agent(2, call: "call_a", turn: "t1"), subagent(3, parent: "call_a", child: "c", turn: "t2")])
        #expect(result.tools[2] == .some(nil))
        #expect(result.loose == [3])
    }

    @Test func replisAncienneForme() throws {
        // Sans `parentToolCallId` : associé seulement s'il reste exactement un appel et une ligne dans le tour.
        let one = cards(try [agent(2, call: "call_a"), subagent(3, parent: nil, child: "c")])
        #expect(one.tools[2] == "c")
        let ambiguous = cards(try [agent(2, call: "call_a"), agent(3, call: "call_b"), subagent(4, parent: nil, child: "c")])
        #expect(ambiguous.tools[2] == .some(nil))
        #expect(ambiguous.tools[3] == .some(nil))
        #expect(ambiguous.loose == [4])
    }

    @Test func identifiantParentVideTraiteCommeAbsent() throws {
        // Comme le web (`!row.parentToolCallId`) : chaîne vide = ancienne forme, repli d'une seule paire par tour.
        let result = cards(try [agent(2, call: "call_a"), subagent(3, parent: "", child: "c")])
        #expect(result.tools[2] == "c")
        #expect(result.loose.isEmpty)
    }

    @Test func seulsLesOutilsDeSousAgent() throws {
        let bash = try agent(2, call: "call_a", name: "Bash", input: ["command": .string("ls")])
        let result = cards([bash, try subagent(3, parent: "call_a", child: "c")])
        #expect(result.tools[2] == .some(nil))
        #expect(result.loose == [3])
        for name in ["Task", "subagent"] {
            #expect(cards(try [agent(2, call: "x", name: name), subagent(3, parent: "x", child: "c")]).tools[2] == "c")
        }
    }

    func link(_ tool: ConversationRow, _ sub: ConversationRow) throws -> SubagentLink {
        for entry in ChatTimeline.entries(from: [tool, sub]) {
            if case .item(.tool(_, _, let link?)) = entry.content { return link }
        }
        throw LinkMissing()
    }
    struct LinkMissing: Error {}

    @Test func titreDuSousAgent() throws {
        let sub = try subagent(3, parent: "x", child: "c", type: "Explore")
        #expect(try link(agent(2, call: "x", extra: ["_meta": .object(["zcode": .object(["nickname": .string(" Ada ")])])]), sub).title == "Ada")
        #expect(try link(agent(2, call: "x", input: ["nickname": .string("Bob"), "description": .string("D")]), sub).title == "Bob")
        #expect(try link(agent(2, call: "x"), sub).title == "Lister les fichiers")
        #expect(try link(agent(2, call: "x", input: ["description": .string("  "), "subagent_type": .string("Plan")]), sub).title == "Plan")
        #expect(try link(agent(2, call: "x", input: ["agent_type": .string("worker")]), sub).title == "worker")
        #expect(try link(agent(2, call: "x", input: [:]), sub).title == "Explore")
    }

    @Test func statutDuSousAgent() throws {
        let tool = try agent(2, call: "x")
        #expect(try link(tool, subagent(3, parent: "x", child: "c", status: "running")).statusLabel == "En cours")
        #expect(try link(tool, subagent(3, parent: "x", child: "c", status: "failed")).statusLabel == "Échec")
        #expect(try link(tool, subagent(3, parent: "x", child: "c", status: "cancelled")).statusLabel == "Annulé")
        let done = try link(tool, subagent(3, parent: "x", child: "c", status: "success"))
        #expect(done.statusLabel == "Terminé")
        #expect(done.isFinishedSuccess)
        #expect(try link(tool, subagent(3, parent: "x", child: "c", status: "paused")).statusLabel == "paused")
    }

    @Test func libellesDesSousAgentsEnCours() {
        #expect(SubagentLabels.runningCount(0) == nil)
        #expect(SubagentLabels.runningCount(1) == "1 sous-agent")
        #expect(SubagentLabels.runningCount(3) == "3 sous-agents")
        #expect(SubagentLabels.runningStatus("running") == "en cours")
        #expect(SubagentLabels.runningStatus("waiting") == "en attente")
        #expect(SubagentLabels.runningStatus("blocked") == "bloqué")
        #expect(SubagentLabels.runningStatus("autre") == "autre")
    }

    @Test func sessionReelle() throws {
        // Fixture de la tâche 0 : trame 004 (fenêtre du parent) et page 005 ; la trame 007 est celle de l'enfant, écartée.
        let records = try Fixtures.records(in: "v3.15.1/subagent-thread")
            .filter { $0.file.hasPrefix("004") || $0.file.hasPrefix("005") }
        #expect(records.count == 2)
        let rows = records.flatMap { record -> [ConversationRow] in
            let window = record.value["frame"]?["payload"]?["snapshot"]?["rows"]?["window"]?.arrayValue
                ?? record.value["rows"]?.arrayValue ?? []
            return window.compactMap(ConversationRow.init(json:))
        }
        let parentRows = Dictionary(rows.map { ($0.rowId, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.rowId < $1.rowId }
        let child = parentRows.compactMap { row -> String? in
            if case .subagent(let value) = row.content { value.childSessionId } else { nil }
        }.first
        let result = cards(parentRows)
        #expect(child != nil)
        #expect(result.tools[4] == child)                            // la carte « Agent » (ligne 4) porte l'enfant
        #expect(result.loose.isEmpty)                                // la ligne `subagent` (5) n'est plus affichée à part
    }
}
