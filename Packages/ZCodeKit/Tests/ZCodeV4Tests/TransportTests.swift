import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct TransportTests {
    @Test func helloReel() throws {
        let value = try Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json")
        let hello = try V4JSON.decode(HelloMessage.self, from: value)
        #expect(hello.protocolVersion == V4Protocol.wireVersion)
        #expect(hello.clientMode == "web-remote-replayable")
        #expect(hello.deliveryProfile == "replayable")
        #expect(hello.capabilities?.workflowRunDeltas == true)
        #expect(hello.capabilities?.binaryFrames == false)
    }

    @Test func helloMinimalTolere() throws {
        // Seul `protocolVersion` conditionne la connexion : un autre champ absent ou renommé ne doit pas la bloquer.
        let hello = try V4JSON.decode(HelloMessage.self, from: .object(["protocolVersion": .number(3), "nouveauChamp": .bool(true)]))
        #expect(hello.protocolVersion == 3)
        #expect(hello.capabilities == nil)
        #expect(hello.connectionId == nil)
    }

    @Test func clientHelloSansCapacites() {
        let hello = ClientHello(clientId: "client-abc", appVersion: "0.1 (12)")
        #expect(hello.json == .object([
            "kind": .string("clientHello"), "protocolVersion": .number(3), "clientId": .string("client-abc"),
            "clientKind": .string("mobileApp"), "appVersion": .string("0.1 (12)"),
        ]))
    }

    @Test func accuseDAbonnementReel() throws {
        let value = try Fixtures.recorded("v3.15.1/send-text/003-result-zcode-agent.subscribeConversationV4.json")
        #expect(try SubscribeAck(result: value) == SubscribeAck(
            subscriptionId: "sub-mv6j6gf9-m0d4m1jc-2", mode: .snapshot, logEpoch: "mv6j6gf9-m0d4m1jc"))
        #expect(throws: V4DecodingError.missingField("ack.subscriptionId")) { try SubscribeAck(result: .object(["ack": .object([:])])) }
    }

    @Test func pageDHistoriqueReelle() throws {
        let value = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        let page = try RowsRangePage(json: value)
        #expect(page.rows.map(\.rowId) == [1, 2, 3, 4])
        #expect(page.atLogEpoch == "mv6j6gf9-m0d4m1jc")
        #expect(page.atRevision == 9)
        #expect(page.atSeq == 13)
        #expect(page.hasMore == false)
    }

    func storeWithPong() throws -> ConversationStore {
        let records = try Fixtures.records(in: "v3.15.1/send-text")
        var store = ConversationStore(topic: Topic.conversation("sess_45199523-12a0-4928-92e6-ff082723da62"))
        _ = store.subscribed(try SubscribeAck(result: records[2].value))
        _ = store.receive(try logical(records[3].value))
        return store
    }

    @Test func pageDHistoriqueFusionnee() throws {
        var store = try storeWithPong()
        var json = try #require(Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json").objectValue)
        var rows = try #require(json["rows"]?.arrayValue)
        rows.insert(.object(["rowId": .number(0), "kind": .string("userInput"), "text": .string("plus ancien")]), at: 0)
        json["rows"] = .array(rows)
        #expect(store.mergeOlderRows(try RowsRangePage(json: .object(json))))
        #expect(store.projection?.rows.map(\.rowId) == [0, 1, 2, 3, 4])
    }

    @Test func pageDUneAutreEpoqueRefusee() throws {
        var store = try storeWithPong()
        var json = try #require(Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json").objectValue)
        json["atLogEpoch"] = .string("autre-epoque")
        json["rows"] = .array([.object(["rowId": .number(0), "kind": .string("userInput"), "text": .string("périmée")])])
        #expect(store.mergeOlderRows(try RowsRangePage(json: .object(json))) == false)
        #expect(store.projection?.rows.map(\.rowId) == [1, 2, 3, 4])
    }

    @Test func cibleDeLigne() throws {
        let store = try storeWithPong()
        let header = try #require(store.projection?.row(id: 1))
        let target = try #require(RowTarget(row: header))
        #expect(target.json == .object(["rowId": .number(1), "entityId": .string("msg_mv6i5rdc_be61022c-a9d5-4a93-bc3c-7cc5ee00727d")]))
        #expect(RowTarget(row: try #require(ConversationRow(json: .object(["rowId": .number(2), "kind": .string("x")])))) == nil)
    }

    @Test func changementsDeFichiers() throws {
        let changes = try V4JSON.decode(FileChanges.self, from: .object([
            "files": .number(1), "additions": .number(1), "deletions": .number(0), "state": .string("active"),
            "items": .array([.object([
                "path": .string("/Users/me/claude/.zcode-check/a.txt"), "additions": .number(1), "deletions": .number(0),
                "writeCount": .number(1), "toolNames": .array([.string("Write")]),
                "patches": .array([.object([
                    "oldStart": .number(0), "oldLines": .number(0), "newStart": .number(1), "newLines": .number(1),
                    "lines": .array([.string("+contrat OK")]),
                ])]),
            ])]),
        ]))
        #expect(changes.items.first?.path.hasSuffix(".zcode-check/a.txt") == true)
        #expect(changes.items.first?.patches.first?.lines == ["+contrat OK"])
    }
}
