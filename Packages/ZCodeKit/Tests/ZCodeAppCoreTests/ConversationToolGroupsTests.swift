import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationToolGroupsTests {
    let turn = "turn-groups"

    func rowJSON(_ rowId: Int, _ kind: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string(turn)
        object["visibility"] = .string("visible")
        return .object(object)
    }

    func tool(_ rowId: Int, approval: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "toolCallId": .string("c\(rowId)"), "toolName": .string("Bash"), "status": .string("success"), "inputText": .string("{}"),
        ]
        if let approval { fields["approvalInteractionId"] = .string(approval) }
        return rowJSON(rowId, "toolCall", fields)
    }

    var question: JSONValue { rowJSON(1, "userInput", ["text": .string("q")]) }
    var answer: JSONValue { rowJSON(4, "assistantText", ["text": .string("ok"), "state": .string("complete")]) }

    /// Snapshot initial : question, outils 2 et 3, réponse 4.
    func ready(_ server: FakeZCodeServer, rows: [JSONValue]? = nil, pending: [JSONValue] = []) async throws -> ConversationModel {
        let window = rows ?? [question, tool(2), tool(3), answer]
        return try await readyConversation(server) { snapshot in
            snapshot["rows"] = .object(["window": .array(window), "totalCount": .number(Double(window.count)), "firstRowId": .number(1)])
            snapshot["pendingInteractions"] = .array(pending)
        }
    }

    func group(_ entry: ChatEntry) -> ToolGroup? {
        if case .toolGroup(let group) = entry.content { group } else { nil }
    }

    @Test func repliéParDéfautPuisDéplié() async throws {
        let server = try await conversationServer()
        let model = try await ready(server)
        let folded = try #require(model.entries.compactMap(group).first)
        #expect(!folded.isExpanded)
        #expect(folded.id == 2)
        #expect(model.entries.map(\.id) == [1, folded.entryId, 4])
        #expect(model.ungroupedEntries.map(\.id) == [1, 2, 3, 4])
        let version = model.contentVersion

        model.toggleToolGroup(folded.id)
        let open = try #require(model.entries.compactMap(group).first)
        #expect(open.isExpanded)
        #expect(model.entries.map(\.id) == [1, open.entryId, 2, 3, 4])
        #expect(model.expandedToolGroups == [2])
        #expect(model.contentVersion == version)

        model.toggleToolGroup(folded.id)
        #expect(try #require(model.entries.compactMap(group).first).isExpanded == false)
        #expect(model.entries.map(\.id) == [1, open.entryId, 4])
        #expect(model.expandedToolGroups.isEmpty)
    }

    @Test func groupeQuiGranditGardeSonÉtat() async throws {
        let server = try await conversationServer()
        let model = try await ready(server, rows: [question, tool(2), tool(3)])
        model.toggleToolGroup(2)
        await server.emit(conversationEvent, try conversationDeltas([.object(["op": .string("row.appended"), "row": tool(4)])]))
        let grown = try await eventually { model.ungroupedEntries.count == 4 ? model.entries.compactMap(group).first : nil }
        #expect(grown.id == 2)
        #expect(grown.isExpanded)
        #expect(grown.members.count == 3)
    }

    @Test func rechercheDéplieLeGroupe() async throws {
        let server = try await conversationServer()
        let model = try await ready(server)
        model.reveal(entryId: 1)                                  // la question : rien
        model.reveal(entryId: 4)                                  // un texte : rien
        model.reveal(entryId: 99)                                 // inconnu : rien
        #expect(model.expandedToolGroups.isEmpty)
        #expect(model.entries.compactMap(group).first?.isExpanded == false)

        model.reveal(entryId: 3)                                  // membre caché
        #expect(model.expandedToolGroups == [2])
        #expect(model.entries.compactMap(group).first?.isExpanded == true)
        model.reveal(entryId: 3)                                  // déjà déplié : toujours déplié
        #expect(model.entries.compactMap(group).first?.isExpanded == true)
    }

    @Test func demandeOuverteRendLaCarteVisible() async throws {
        let server = try await conversationServer()
        let model = try await ready(server, rows: [question, tool(2), tool(3, approval: "perm_bash"), answer],
                                    pending: [try syntheticInteraction("perm_bash")])
        let g = try #require(model.entries.compactMap(group).first)
        #expect(!g.isExpanded)
        #expect(model.entries.map(\.id) == [1, g.entryId, 3, 4])   // la carte 3 reste sous le groupe replié
    }

    @Test func groupementEnLectureSeule() async throws {
        // Copie hors ligne affichée sans serveur.
        let cache = ConversationCache()
        let key = SessionKey(hostId: testHost.id, workspace: testWorkspacePath, sessionId: pongSession)
        let frame = try initialConversationFrame { snapshot in
            snapshot["rows"] = .object(["window": .array([question, tool(2), tool(3), answer]), "totalCount": .number(4), "firstRowId": .number(1)])
        }
        let snapshot = try ConversationSnapshot(json: #require(frame["frame"]?["payload"]?["snapshot"]))
        await cache.saveConversation(snapshot, key: key, savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let offline = makeConversation(ServerQueue([]), cache: cache)
        await offline.start()
        #expect(offline.offlineCopyDate != nil)
        #expect(offline.entries.compactMap(group).count == 1)
        #expect(offline.ungroupedEntries.map(\.id) == [1, 2, 3, 4])

        // Passage hors ligne d'un état vivant : le groupe déplié reste déplié.
        let server = try await conversationServer()
        let live = try await ready(server)
        live.toggleToolGroup(2)
        server.transport.finish()
        _ = try await eventually { live.offlineCopyDate != nil ? true : nil }
        #expect(live.entries.compactMap(group).first?.isExpanded == true)
    }
}
