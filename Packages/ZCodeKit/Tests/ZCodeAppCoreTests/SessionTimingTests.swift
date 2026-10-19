import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SessionTimingTests {
    let labels = TimeLabels(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "fr_FR"))

    func call(_ status: String, startedAt: Double? = nil, endedAt: Double? = nil) throws -> ToolCall {
        var object: [String: JSONValue] = ["rowId": .number(1), "kind": .string("toolCall"), "toolCallId": .string("c"),
                                           "toolName": .string("Bash"), "status": .string(status), "inputText": .string("{}")]
        if let startedAt { object["startedAt"] = .number(startedAt) }
        if let endedAt { object["endedAt"] = .number(endedAt) }
        guard case .toolCall(let value) = try #require(ConversationRow(json: .object(object))).content else {
            throw FixtureError.noRecord(folder: "toolCall", prefix: status)
        }
        return value
    }

    @Test func carteReelleTerminee() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text-long/003-event-zcode-agent.onDynamicConversationFrame.json")
        let snapshot = try ConversationSnapshot(json: #require(wire["frame"]?["payload"]?["snapshot"]))
        let tool = try #require(snapshot.rows.compactMap { row -> ToolCall? in
            if case .toolCall(let value) = row.content { value } else { nil }
        }.first)
        #expect(tool.timing == .finished(milliseconds: 230))       // 1791886889163 − 1791886888933
        #expect(tool.timing?.label(now: .now) == "< 1 s")
        #expect(tool.boundsLabel(labels) == "Début 12:21:28 · Fin 12:21:29")
    }

    @Test func carteEnCoursDefile() throws {
        let tool = try call("running", startedAt: 1_000_000)
        #expect(tool.timing == .running(since: 1_000_000))
        #expect(tool.timing?.label(now: Date(timeIntervalSince1970: 1_003.25)) == "3,2 s")
        #expect(tool.timing?.label(now: Date(timeIntervalSince1970: 1_125)) == "2 min 05 s")
        #expect(tool.timing?.label(now: Date(timeIntervalSince1970: 990)) == "< 1 s")    // horloges décalées
        #expect(tool.boundsLabel(labels)?.hasSuffix(" · en cours") == true)
    }

    @Test func dureeFigeeQuelQueSoitLeStatut() throws {
        #expect(try call("error", startedAt: 0, endedAt: 42_900).timing == .finished(milliseconds: 42_900))
        #expect(try call("cancelled", startedAt: 0, endedAt: 1_500).timing?.label(now: .now) == "1,5 s")
        #expect(try call("running", startedAt: 0, endedAt: 2_000).timing == .finished(milliseconds: 2_000))
    }

    @Test func pasDeDureeSansDebut() throws {
        #expect(try call("running").timing == nil)
        #expect(try call("pendingApproval").timing == nil)
        #expect(try call("inputStreaming", startedAt: 5).timing == nil)
        #expect(try call("success", startedAt: 5).timing == nil)    // terminée sans endedAt : rien d'inventé
        #expect(try call("success").boundsLabel(labels) == nil)
        #expect(try call("success", startedAt: 1_791_886_888_933).boundsLabel(labels) == "Début 12:21:28")
    }

    func snapshot(_ folder: String, _ prefix: String) throws -> ConversationSnapshot {
        let wire = try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
        return try ConversationSnapshot(json: #require(wire["frame"]?["payload"]?["snapshot"]))
    }

    func header(_ rowId: Int, _ state: String, startedAt: Double? = nil, activeMs: Double? = nil) throws -> ConversationRow {
        var object: [String: JSONValue] = ["rowId": .number(Double(rowId)), "kind": .string("turnHeader"),
                                           "turnId": .string("t\(rowId)"), "state": .string(state)]
        if let startedAt { object["startedAt"] = .number(startedAt) }
        if let activeMs { object["activeMs"] = .number(activeMs) }
        return try #require(ConversationRow(json: .object(object)))
    }

    @Test func sommeDesToursReels() throws {
        let work = SessionWorkTime(rows: try snapshot("send-text-long", "003").rows, partial: false)
        #expect(work.completedMs == 2784 + 6865)
        #expect(!work.isRunning)
        #expect(work.label(now: .now) == "9 s de travail")
    }

    @Test func tourEnCoursCompteDepuisSonDebut() throws {
        let rows = try [header(1, "completedSuccess", activeMs: 60_000),
                        header(2, "running", startedAt: 1_000_000, activeMs: 999_999)]   // activeMs périmé : ignoré
        let work = SessionWorkTime(rows: rows, partial: false)
        #expect(work.runningStarts == [1_000_000])
        #expect(work.totalMs(now: Date(timeIntervalSince1970: 1_120)) == 180_000)
        #expect(work.label(now: Date(timeIntervalSince1970: 1_120)) == "3 min de travail")
    }

    @Test func tourEnCoursDansLeFutur() throws {
        let work = SessionWorkTime(rows: [try header(1, "running", startedAt: 2_000_000)], partial: false)
        #expect(work.totalMs(now: Date(timeIntervalSince1970: 1_000)) == 0)                // jamais négatif
    }

    @Test func toursSansDuree() throws {
        let rows = try [header(1, "running"), header(2, "failed"), header(3, "étatInconnu", activeMs: 5_000)]
        let work = SessionWorkTime(rows: rows, partial: false)
        #expect(work.completedMs == 5_000)
        #expect(!work.isRunning)                                                            // pas de début : pas de compteur
        #expect(SessionWorkTime(rows: [], partial: true).label(now: .now) == nil)           // aucun tour : rien
    }

    @Test func historiquePartiel() throws {
        let work = SessionWorkTime(rows: [try header(5, "completedSuccess", activeMs: 47 * 60_000)], partial: true)
        #expect(work.label(now: .now) == "≥ 47 min de travail")
    }

    @Test func ligneDEnTete() throws {
        let now = Date(timeIntervalSince1970: 1_791_896_400)                                // 13/10/2026 15:00 Paris
        let work = SessionWorkTime(rows: try snapshot("send-text-long", "003").rows, partial: false)
        let created = 1_791_885_161_375.0                                                  // index : 11:52:41
        #expect(SessionDurations.line(work: work, createdAt: created, now: now, labels: labels)
                == "9 s de travail · créée il y a 3 h 07")
        #expect(SessionDurations.line(work: work, createdAt: nil, now: now, labels: labels) == "9 s de travail")
        #expect(SessionDurations.line(work: .empty, createdAt: created, now: now, labels: labels) == "créée il y a 3 h 07")
        #expect(SessionDurations.line(work: .empty, createdAt: nil, now: now, labels: labels) == nil)
        #expect(SessionDurations.exactCreation(created, now: now, labels: labels) == "Créée le mardi 13 octobre, 11:52:41")
    }
}

/// Modèles qui portent le temps de travail et la date de création (lot 13F).
@MainActor
struct SessionTimingModelTests {
    /// Conversation PONG abonnée dont le snapshot est remplacé par celui de `send-text-long/003`
    /// (`edit` retouche ensuite ses `rows`).
    func longModel(_ edit: (inout [String: JSONValue]) throws -> Void = { _ in }) async throws -> ConversationModel {
        let server = try await conversationServer()
        let wire = try Fixtures.record(in: "v3.15.1/send-text-long", prefix: "003")
        let long = try #require(wire["frame"]?["payload"]?["snapshot"]?["rows"]?.objectValue)
        let frame = try initialConversationFrame { snapshot in
            var rows = long
            try edit(&rows)
            snapshot["rows"] = .object(rows)
        }
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, frame)
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func workTimeSuitLeSnapshot() async throws {
        let whole = try await longModel()
        #expect(whole.hasOlderRows == false)
        #expect(whole.workTime.completedMs == 9_649)
        #expect(whole.workTime.partial == false)

        // Fenêtre qui ne commence pas à `firstRowId` : une partie de l'historique manque, le total est minoré.
        let partial = try await longModel { rows in
            rows["window"] = .array(Array((rows["window"]?.arrayValue ?? []).dropFirst(4)))
            rows["firstRowId"] = .number(1)
        }
        #expect(partial.hasOlderRows == true)
        #expect(partial.workTime.partial == true)
    }

    @Test func dateDeCreationLueDansLIndex() async throws {
        let server = try await sessionsServer()
        let store = HostStore(persistence: InMemoryHostPersistence(), tokens: InMemoryTokenStore())
        let host = try store.add(name: "Mac", url: "mac.ts.net", token: "jeton")
        let app = AppModel(hostStore: store, dependencies: makeDependencies(servers: ServerQueue([server])))
        // Aucun SessionsModel créé : l'index n'est pas chargé.
        #expect(app.sessionCreatedAt(host: host, workspace: testWorkspacePath, sessionId: pongSession) == nil)
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        #expect(app.sessionCreatedAt(host: host, workspace: testWorkspacePath, sessionId: pongSession) == 1_791_885_161_375)
        #expect(app.sessionCreatedAt(host: host, workspace: testWorkspacePath, sessionId: "inconnue") == nil)
        #expect(app.sessionCreatedAt(host: host, workspace: "/autre/projet", sessionId: pongSession) == nil)
    }
}
