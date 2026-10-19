import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ConversationSearchTests {
    func row(_ rowId: Int, _ kind: String, _ fields: [String: JSONValue]) throws -> ConversationRow {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string("t\(rowId)")
        return try #require(ConversationRow(json: .object(object)))
    }

    /// Lignes 2 à 6 : message, réponse, outil Bash, raisonnement, message sans « pong ».
    func entries(withOlder older: Bool = false) throws -> [ChatEntry] {
        var rows = try [
            row(2, "userInput", ["text": .string("Réponse PONG attendue")]),
            row(3, "assistantText", ["text": .string("pong final"), "state": .string("complete")]),
            row(4, "toolCall", [
                "toolCallId": .string("c"), "toolName": .string("Bash"), "status": .string("success"),
                "inputText": .string(""), "input": .object(["command": .string("grep -r pong .")]),
            ]),
            row(5, "reasoning", ["text": .string("pong caché"), "state": .string("complete")]),
            row(6, "userInput", ["text": .string("autre chose")]),
        ]
        if older { rows.insert(try row(1, "userInput", ["text": .string("pong ancien")]), at: 0) }
        return ChatTimeline.entries(from: rows)
    }

    @Test func correspondancesSansCasseNiAccents() throws {
        let entries = try entries()
        #expect(ConversationSearch.matchingIds(in: entries, query: "PONG") == [2, 3, 4])   // pas le raisonnement
        #expect(ConversationSearch.matchingIds(in: entries, query: " reponse ") == [2])
        #expect(ConversationSearch.matchingIds(in: entries, query: "bash") == [4])           // nom de l'outil
        #expect(ConversationSearch.matchingIds(in: entries, query: "  ").isEmpty)
    }

    @Test func titreDuSousAgentDeLaCarte() throws {
        var fields: [ConversationRow] = []
        for (id, kind, extra) in [
            (2, "toolCall", ["toolCallId": JSONValue.string("a"), "toolName": .string("Agent"), "status": .string("success"),
                             "inputText": .string(""), "input": .object([:]), "nickname": .string("Zorglub")]),
            (3, "subagent", ["subagentType": JSONValue.string("Explore"), "status": .string("running"),
                             "summaryText": .string(""), "parentToolCallId": .string("a")]),
        ] {
            var object = extra
            object["rowId"] = .number(Double(id))
            object["kind"] = .string(kind)
            object["turnId"] = .string("t1")
            fields.append(try #require(ConversationRow(json: .object(object))))
        }
        let entries = ChatTimeline.entries(from: fields)
        #expect(ConversationSearch.matchingIds(in: entries, query: "zorglub") == [2])
    }

    @Test func selectionLaPlusRecenteEtNavigationEnBoucle() throws {
        var search = ConversationSearch()
        search.update(query: "pong", entries: try entries())
        #expect(search.currentId == 4)
        #expect(search.counter == "3/3")
        search.previous()
        #expect(search.currentId == 3)
        #expect(search.counter == "2/3")
        search.previous()
        search.previous()
        #expect(search.currentId == 4)                                                     // en boucle vers le haut
        search.next()
        #expect(search.currentId == 2)                                                     // en boucle vers le bas
    }

    @Test func aucunResultatEtRequeteVide() throws {
        var search = ConversationSearch()
        search.update(query: "zzz", entries: try entries())
        #expect(search.counter == "Aucun résultat")
        #expect(search.currentId == nil)
        search.next()
        search.previous()
        #expect(search.currentId == nil)
        search.update(query: "", entries: try entries())
        #expect(search.counter == nil)
    }

    @Test func pageAncienneGardeLaSelection() throws {
        var search = ConversationSearch()
        search.update(query: "pong", entries: try entries())
        search.previous()
        #expect(search.counter == "2/3")
        search.refresh(entries: try entries(withOlder: true))                               // ligne 1 chargée devant
        #expect(search.matches == [1, 2, 3, 4])
        #expect(search.currentId == 3)
        #expect(search.counter == "3/4")
    }

    @Test func selectionVoulueAppliqueeAuChargement() throws {
        var search = ConversationSearch()
        search.update(query: "pong", entries: try entries())
        search.select(1)                                                                   // pas encore chargée
        #expect(search.currentId == 4)
        search.refresh(entries: try entries(withOlder: true))
        #expect(search.currentId == 1)
        #expect(search.counter == "1/4")
    }

    @Test func correspondanceDisparue() throws {
        var search = ConversationSearch()
        search.update(query: "pong", entries: try entries())
        search.previous()                                                                  // ligne 3
        let withoutAnswer = try entries().filter { $0.id != 3 }
        search.refresh(entries: withoutAnswer)
        #expect(search.currentId == 4)
        #expect(search.counter == "2/2")
    }
}

@MainActor
struct ConversationSearchOlderTests {
    func readyModel(_ server: FakeZCodeServer, frame: JSONValue) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, frame)
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    /// Fenêtre réelle décalée en 1001…1004 ; l'hôte annonce l'historique depuis la ligne 1.
    func longHistoryFrame() throws -> JSONValue {
        try initialConversationFrame { snapshot in
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array(try (rows["window"]?.arrayValue ?? []).map { row in
                var object = try #require(row.objectValue)
                object["rowId"] = .number((row["rowId"]?.numberValue ?? 0) + 1000)
                return .object(object)
            })
            rows["firstRowId"] = .number(1)
            rows["totalCount"] = .number(1004)
            snapshot["rows"] = .object(rows)
        }
    }

    /// Chaque page : deux messages juste avant `beforeRowId` ; « aiguille » dans le texte de la ligne `needle`.
    func servePages(_ server: FakeZCodeServer, needle: Int? = nil) async throws {
        let recorded = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        let epoch = try #require(recorded["atLogEpoch"])
        await server.on("zcode-agent.conversationRowsRangeV4") { argument in
            let before = V4JSON.integer(argument["beforeRowId"]) ?? 0
            let rows: [JSONValue] = [before - 2, before - 1].map { id in
                .object([
                    "rowId": .number(Double(id)), "kind": .string("userInput"), "turnId": .string("t\(id)"),
                    "text": .string(id == needle ? "une aiguille ici" : "ligne \(id)"),
                ])
            }
            return .object([
                "rows": .array(rows), "atLogEpoch": epoch, "atRevision": .number(9), "atSeq": .number(13),
                "hasMore": .bool(true),
            ])
        }
    }

    /// Chaque page : deux cartes d'outils réussies d'un même tour (groupe replié, aucune visible) ; la commande de la
    /// ligne `needle` contient « aiguille ».
    func serveToolPages(_ server: FakeZCodeServer, needle: Int) async throws {
        let recorded = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        let epoch = try #require(recorded["atLogEpoch"])
        await server.on("zcode-agent.conversationRowsRangeV4") { argument in
            let before = V4JSON.integer(argument["beforeRowId"]) ?? 0
            let rows: [JSONValue] = [before - 2, before - 1].map { id in
                .object([
                    "rowId": .number(Double(id)), "kind": .string("toolCall"), "turnId": .string("tp\(before)"),
                    "toolCallId": .string("c\(id)"), "toolName": .string("Bash"), "status": .string("success"),
                    "inputText": .string(id == needle ? "{\"command\":\"echo aiguille\"}" : "{\"command\":\"ls\"}"),
                ])
            }
            return .object([
                "rows": .array(rows), "atLogEpoch": epoch, "atRevision": .number(9), "atSeq": .number(13),
                "hasMore": .bool(true),
            ])
        }
    }

    /// Fenêtre réelle réduite aux lignes 3 et 4 ; la page enregistrée apporte les lignes 1 et 2 (fin de l'historique).
    func shortHistory(_ server: FakeZCodeServer) async throws -> ConversationModel {
        let page = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        await server.on("zcode-agent.conversationRowsRangeV4") { _ in page }
        let frame = try initialConversationFrame { snapshot in
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array((rows["window"]?.arrayValue ?? []).filter { ($0["rowId"]?.numberValue ?? 0) >= 3 })
            snapshot["rows"] = .object(rows)
        }
        return try await readyModel(server, frame: frame)
    }

    @Test func chercherPlusLoinPageParPage() async throws {
        let server = try await conversationServer()
        try await servePages(server, needle: 995)
        let model = try await readyModel(server, frame: longHistoryFrame())
        #expect(await model.searchOlder("AIGUILLE") == .found(995))
        #expect(await server.calls(to: "zcode-agent.conversationRowsRangeV4").count == 3)   // 999-1000, 997-998, 995-996
        #expect(model.entries.contains { $0.id == 995 })
    }

    @Test func chercherPlusLoinDixPagesAuPlus() async throws {
        let server = try await conversationServer()
        try await servePages(server)
        let model = try await readyModel(server, frame: longHistoryFrame())
        #expect(await model.searchOlder("aiguille") == .limitReached)
        #expect(await server.calls(to: "zcode-agent.conversationRowsRangeV4").count == ConversationModel.searchPagesPerGesture)
        #expect(model.hasOlderRows)
    }

    @Test func chercherPlusLoinTrouveSansCasseNiAccents() async throws {
        let server = try await conversationServer()
        let model = try await shortHistory(server)
        #expect(await model.searchOlder("REPONDS") == .found(2))                            // « réponds moi PONG »
    }

    @Test func chercherPlusLoinJusquAuDebut() async throws {
        let server = try await conversationServer()
        let model = try await shortHistory(server)
        #expect(await model.searchOlder("zzz") == .exhausted)
        #expect(await model.searchOlder("zzz") == .exhausted)                                // plus rien à lire
        #expect(await server.calls(to: "zcode-agent.conversationRowsRangeV4").count == 1)
    }

    @Test func chercherPlusLoinEnEchec() async throws {
        struct Indisponible: Error {}
        let server = try await conversationServer()
        await server.on("zcode-agent.conversationRowsRangeV4") { _ in throw Indisponible() }
        let model = try await readyModel(server, frame: longHistoryFrame())
        #expect(await model.searchOlder("aiguille") == .failed)
        #expect(model.olderRowsFailed)
    }

    /// Régression 13B : la recherche lit les entrées à plat, pas les groupes repliés qui cachent leurs cartes.
    @Test func chercherPlusLoinTrouveUneCarteCacheeDansUnGroupe() async throws {
        let server = try await conversationServer()
        try await serveToolPages(server, needle: 999)
        let model = try await readyModel(server, frame: longHistoryFrame())
        #expect(await model.searchOlder("aiguille") == .found(999))
        #expect(!model.entries.contains { $0.id == 999 })                                   // cachée par le groupe replié
        #expect(model.ungroupedEntries.contains { $0.id == 999 })
    }
}
