import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SessionsIndexTests {
    func realIndex() throws -> SessionsIndex {
        let wire = try Fixtures.recorded("v3.15.1/handshake-sessions/004-event-zcode-agent.onDynamicSessionsIndexFrame.json")
        return try SessionsIndex(json: #require(wire["frame"]?["payload"]?["snapshot"]))
    }

    func summary(_ id: String, title: String, at: Double, phase: String = "running") -> JSONValue {
        .object([
            "sessionId": .string(id), "workspaceId": .string("/Users/me/claude"), "title": .string(title),
            "phase": .string(phase), "sessionEnded": .bool(false), "hasBackgroundWork": .bool(false),
            "lastActivityAt": .number(at), "createdAt": .number(at),
        ])
    }

    @Test func indexReel() throws {
        let index = try realIndex()
        #expect(index.workspaceId == "/Users/me/claude")
        #expect(index.logEpoch == "mv6icva5-jgvj76zm")
        #expect(index.sessions.count == 1)
        let session = try #require(index.sessions.first)
        #expect(session.id == "sess_45199523-12a0-4928-92e6-ff082723da62")
        #expect(session.title == "Demande de réponse PONG")
        #expect(session.phase == .completedSuccess)
        #expect(session.lastAssistantPreview == "PONG")
    }

    @Test func ajoutMiseAJourEtSuppression() throws {
        var index = try realIndex()
        index.apply([
            SessionsIndexDelta(json: .object(["op": .string("session.upserted"), "session": summary("sess_b", title: "Nouvelle", at: 2e12)])),
            SessionsIndexDelta(json: .object(["op": .string("session.upserted"), "session": summary("sess_b", title: "Renommée", at: 3e12)])),
        ])
        #expect(index.sessions.count == 2)
        #expect(index.session(id: "sess_b")?.title == "Renommée")
        #expect(index.byRecentActivity.map(\.sessionId) == ["sess_b", "sess_45199523-12a0-4928-92e6-ff082723da62"])
        index.apply(SessionsIndexDelta(json: .object(["op": .string("session.removed"), "sessionId": .string("sess_b")])))
        #expect(index.session(id: "sess_b") == nil)
        #expect(index.sessions.count == 1)
    }

    @Test func toleranceAuxEvolutions() throws {
        var index = try realIndex()
        let future = SessionsIndexDelta(json: .object(["op": .string("session.archived"), "sessionId": .string("x")]))
        guard case .unknown(op: "session.archived", _) = future else { Issue.record("op inconnu attendu"); return }
        index.apply(future)
        index.apply(SessionsIndexDelta(json: .object(["op": .string("session.upserted"), "session": .object(["sessionId": .string("incomplet")])])))
        #expect(index.sessions.count == 1)                               // entrée mal formée ignorée
        var snapshot = try #require(Fixtures.recorded("v3.15.1/handshake-sessions/004-event-zcode-agent.onDynamicSessionsIndexFrame.json")["frame"]?["payload"]?["snapshot"]?.objectValue)
        var sessions = try #require(snapshot["sessions"]?.arrayValue)
        sessions.append(.object(["sessionId": .string("cassee")]))
        sessions.append(summary("sess_futur", title: "Futur", at: 1, phase: "hibernating"))
        snapshot["sessions"] = .array(sessions)
        let tolerant = try SessionsIndex(json: .object(snapshot))
        #expect(tolerant.sessions.map(\.sessionId) == ["sess_45199523-12a0-4928-92e6-ff082723da62", "sess_futur"])
        #expect(tolerant.session(id: "sess_futur")?.phase.rawValue == "hibernating")
        #expect(throws: V4DecodingError.missingField("sessions")) { try SessionsIndex(json: .object(["workspaceId": .string("w"), "logEpoch": .string("e")])) }
    }
}
