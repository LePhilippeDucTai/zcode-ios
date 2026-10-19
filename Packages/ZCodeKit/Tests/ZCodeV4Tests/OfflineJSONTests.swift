import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct OfflineJSONTests {
    @Test func snapshotAllerRetour() throws {
        let original = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text-long", "003"))))
        let copy = try ConversationSnapshot(json: original.offlineJSON(keepingLast: 60))
        #expect(copy == original)
    }

    @Test func snapshotGardeLesDernièresLignes() throws {
        let original = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text-long", "003"))))
        #expect(original.rows.count > 2)
        let copy = try ConversationSnapshot(json: original.offlineJSON(keepingLast: 2))
        #expect(copy.rows.map(\.rowId) == original.rows.suffix(2).map(\.rowId))
        #expect(copy.totalCount == original.totalCount)
        #expect(copy.firstRowId == original.firstRowId)
        #expect(copy.state == original.state)
    }

    @Test func indexAllerRetour() throws {
        let wire = try Fixtures.recorded("v3.15.1/handshake-sessions/004-event-zcode-agent.onDynamicSessionsIndexFrame.json")
        let original = try SessionsIndex(json: #require(wire["frame"]?["payload"]?["snapshot"]))
        let copy = try SessionsIndex(json: original.offlineJSON(excluding: []))
        #expect(copy == original)
    }

    @Test func indexSansSessionsCachées() throws {
        var index = try SessionsIndex(json: .object([
            "workspaceId": .string("/w"), "logEpoch": .string("e"), "sessions": .array([]),
        ]))
        for id in ["a", "b"] {
            index.apply(.upserted(try V4JSON.decode(SessionSummary.self, from: .object([
                "sessionId": .string(id), "workspaceId": .string("/w"), "title": .string(id),
                "phase": .string("idle"), "lastActivityAt": .number(1),
            ]))))
        }
        let copy = try SessionsIndex(json: index.offlineJSON(excluding: ["a"]))
        #expect(copy.sessions.map(\.sessionId) == ["b"])
        #expect(copy.logEpoch == "e")
    }
}
