import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

struct ToolGroupTests {
    /// Entrée construite par `ChatTimeline` (`ChatEntry` n'a pas d'init public), un tour par ligne.
    func entry(_ rowId: Int, _ kind: String, _ fields: [String: JSONValue]) throws -> ChatEntry {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string("t1")
        let row = try #require(ConversationRow(json: .object(object)))
        return try #require(ChatTimeline.entries(from: [row]).first)
    }

    func tool(_ rowId: Int, _ name: String, status: String = "success", startedAt: Double? = nil, endedAt: Double? = nil) throws -> ChatEntry {
        var fields: [String: JSONValue] = [
            "toolCallId": .string("c\(rowId)"), "toolName": .string(name), "status": .string(status), "inputText": .string("{}"),
        ]
        if let startedAt { fields["startedAt"] = .number(startedAt) }
        if let endedAt { fields["endedAt"] = .number(endedAt) }
        return try entry(rowId, "toolCall", fields)
    }

    func reasoning(_ rowId: Int, durationMs: Double? = nil) throws -> ChatEntry {
        var fields: [String: JSONValue] = ["text": .string("hmm"), "state": .string("complete")]
        if let durationMs { fields["durationMs"] = .number(durationMs) }
        return try entry(rowId, "reasoning", fields)
    }

    @Test func famillesSansCasse() {
        #expect(ToolFamily(toolName: "bash") == .command)
        #expect(ToolFamily(toolName: "MultiEdit") == .write)
        #expect(ToolFamily(toolName: "WebSearch") == .web)
        #expect(ToolFamily(toolName: "mcp__x__y") == .other)
    }

    @Test func libelléAvecRéflexion() throws {
        let group = try ToolGroup(id: 1, members: [reasoning(1), tool(2, "Bash"), tool(3, "Bash"), tool(4, "Read")], isExpanded: false)
        #expect(group.summary == "A réfléchi, exécuté 2 commandes, lu 1 fichier")
    }

    @Test func libelléSansRéflexionEtÉchec() throws {
        let group = try ToolGroup(id: 2, members: [tool(2, "Grep"), tool(3, "Edit", status: "error"), tool(4, "TodoWrite")], isExpanded: false)
        #expect(group.summary == "A modifié 1 fichier, fait 1 recherche, mis à jour les tâches · 1 échec")
        #expect(group.failureCount == 1)
    }

    @Test func ordreDeLaTable() throws {
        let group = try ToolGroup(id: 1, members: [tool(1, "mcp__a"), tool(2, "WebFetch"), tool(3, "Skill"), tool(4, "Agent")], isExpanded: false)
        #expect(group.summary == "A consulté 1 page web, utilisé 1 skill, lancé 1 sous-agent, utilisé 1 autre outil")
    }

    @Test func pluriels() throws {
        let group = try ToolGroup(id: 1, members: [
            tool(1, "Write"), tool(2, "Glob"), tool(3, "Grep"), tool(4, "WebFetch"), tool(5, "WebSearch"), tool(6, "Skill"), tool(7, "Skill"),
            tool(8, "Task"), tool(9, "Task"), tool(10, "x"), tool(11, "y"), tool(12, "Bash", status: "error"), tool(13, "Bash", status: "error"),
        ], isExpanded: false)
        #expect(group.summary == "A exécuté 2 commandes, modifié 1 fichier, fait 2 recherches, consulté 2 pages web, utilisé 2 skills, "
            + "lancé 2 sous-agents, utilisé 2 autres outils · 2 échecs")
    }

    @Test func réflexionsSeules() throws {
        #expect(try ToolGroup(id: 1, members: [reasoning(1), reasoning(2)], isExpanded: false).summary == "A réfléchi")
    }

    @Test func identités() throws {
        let group = try ToolGroup(id: 7, members: [tool(7, "Bash")], isExpanded: true)
        #expect(group.id == 7)
        #expect(group.isExpanded)
        #expect(group.entryId == -(1 << 33) - 7)
    }

    @Test func duréeTotale() throws {
        let now = Date(timeIntervalSince1970: 10)
        let known = try ToolGroup(id: 1, members: [
            tool(1, "Bash", startedAt: 0, endedAt: 1500), tool(2, "Read", startedAt: 0, endedAt: 500), reasoning(3, durationMs: 1000),
        ], isExpanded: false)
        #expect(known.durationMs(now: now) == 3000)
        #expect(!known.isRunning)

        let unknown = try ToolGroup(id: 2, members: [tool(1, "Bash"), reasoning(2)], isExpanded: false)
        #expect(unknown.durationMs(now: now) == nil)

        // Outil en cours depuis 4 s (10 000 − 6 000 ms) + outil fini 500 ms.
        let running = try ToolGroup(id: 3, members: [
            tool(1, "Bash", status: "running", startedAt: 6000), tool(2, "Read", startedAt: 0, endedAt: 500),
        ], isExpanded: false)
        #expect(running.durationMs(now: now) == 4500)
        #expect(running.isRunning)
    }
}
