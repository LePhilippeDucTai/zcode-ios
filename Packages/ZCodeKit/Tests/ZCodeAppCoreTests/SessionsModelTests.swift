import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct SessionsModelTests {
    func makeModel(_ servers: ServerQueue, archiveStore: ArchiveStore = ArchiveStore(), seenStore: SeenStore = SeenStore(),
                   pinStore: PinStore = PinStore(), cache: ConversationCache? = nil,
                   now: @escaping @Sendable () -> Date = Date.init,
                   serverInfo: @escaping @Sendable () throws -> ServerInfo = { makeServerInfo() }) -> SessionsModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: servers, serverInfo: serverInfo))
        return SessionsModel(connection: connection, workspace: testWorkspacePath, archiveStore: archiveStore,
                             seenStore: seenStore, pinStore: pinStore, cache: cache, now: now)
    }

    @Test func epingleeEnTeteEtOublieeQuandElleDisparait() async throws {
        let server = try await sessionsServer()
        let pins = PinStore()
        let gone = SessionKey(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_partie")
        pins.setPinned(true, gone)
        let model = makeModel(ServerQueue([server]), pinStore: pins)
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(!pins.isPinned(gone))                                             // absente de l'index : retirée
        #expect(model.layout(query: "").recent.map(\.sessionId) == [pongSession])
        model.togglePin(pongSession)
        #expect(model.isPinned(pongSession))
        #expect(model.layout(query: "").pinned.map(\.sessionId) == [pongSession])
        #expect(model.layout(query: "").recent.isEmpty)
        model.togglePin(pongSession)
        #expect(!model.isPinned(pongSession))
    }

    /// Tâche archivée telle que `zcode-task.listArchivedTasks` la renvoie (`taskId` = identifiant de session).
    func archivedTaskJSON(_ sessionId: String, title: String = "Archivée", updatedAt: Double = 1_791_890_000_000) -> JSONValue {
        .object([
            "taskId": .string(sessionId), "title": .string(title), "workspacePath": .string(testWorkspacePath),
            "traceId": .string("trace_1"), "createdAt": .number(1_791_880_000_000), "updatedAt": .number(updatedAt),
            "mode": .string("chat"),
        ])
    }

    /// Serveur d'index qui répond aussi sur le canal `zcode-task` (`archived` : tâches listées comme archivées).
    func taskIndexServer(archived: [JSONValue] = [], deleted: [String] = []) async throws -> FakeZCodeServer {
        let server = try await sessionsServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array(archived) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array(deleted.map(JSONValue.string)) }
        await server.on("zcode-task.archiveTask") { _ in .object(["taskId": .string("ok")]) }
        await server.on("zcode-task.unarchiveTask") { _ in .object(["taskId": .string("ok")]) }
        await server.on("zcode-task.deleteArchivedTask") { _ in .bool(true) }
        return server
    }

    @Test func chargementDeLIndex() async throws {
        let server = try await sessionsServer()
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        let sessions = try await eventually { model.phase == .ready ? model.sessions : nil }
        #expect(sessions.map(\.title) == ["Demande de réponse PONG"])
        #expect(await server.calls(to: "zcode-agent.subscribeSessionsIndexV4") == [.object(["workspacePath": .string(testWorkspacePath)])])
    }

    @Test func sessionCreeeVisibleAvantPublication() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                "revisionAtDecision": .number(0),
                "result": .object(["type": .string("createSession"), "sessionId": .string("sess_neuve")]),
            ])
        }
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        let sessionId = try await model.createSession(builder: CommandBuilder(clientId: "client-test"))
        #expect(sessionId == "sess_neuve")
        #expect(model.drafts == ["sess_neuve"])                              // visible tout de suite
        let command = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first)
        #expect(command["envelope"]?["type"] == .string("createSession"))
        #expect(command["envelope"]?["payload"] == .object(["workspaceId": .string(testWorkspacePath)]))
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON("sess_neuve")))   // premier message envoyé
        _ = try await eventually { model.sessions.count == 2 ? true : nil }
        #expect(model.drafts.isEmpty)                                         // publiée : plus de doublon local
    }

    @Test func sessionCreeeAvecLeModeParDefautDeLHote() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                "revisionAtDecision": .number(0),
                "result": .object(["type": .string("createSession"), "sessionId": .string("sess_neuve")]),
            ])
        }
        var host = testHost
        host.defaultMode = "plan"
        let connection = HostConnection(host: host, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let model = SessionsModel(connection: connection, workspace: testWorkspacePath)
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        _ = try await model.createSession(builder: CommandBuilder(clientId: "client-test"))
        let command = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first)
        #expect(command["envelope"]?["payload"] == .object([
            "workspaceId": .string(testWorkspacePath),
            "config": .object(["mode": .string("build"), "planEnabled": .bool(true)]),
        ]))
    }

    @Test func perteDeConnexionReabonneSurUnNouveauCanal() async throws {
        let first = try await sessionsServer()
        let second = try await sessionsServer()
        let servers = ServerQueue([first, second])
        let model = makeModel(servers)
        await model.start()
        try await emitWhenListening(first, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        first.transport.finish()                                              // Mac en veille : la connexion tombe
        try await emitWhenListening(second, initialIndexFrame())
        _ = try await eventually { model.phase == .ready && servers.opened == 2 ? true : nil }
        #expect(model.sessions.count == 1)
    }

    @Test func tokenRefuseAffiche() async {
        let model = makeModel(ServerQueue([]), serverInfo: { throw ServerInfoError.unauthorized })
        await model.start()
        #expect(model.phase == .failed(ConnectionFailure.unauthorized.message))
        await #expect(throws: SessionsError.notConnected(ConnectionFailure.unauthorized.message)) {
            try await model.createSession(builder: CommandBuilder(clientId: "client-test"))
        }
    }

    @Test func rafraichissementsSimultanesUnSeulAbonnement() async throws {
        let server = try await sessionsServer()
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        async let first: Void = model.refresh()                                  // double tap sur « Réessayer »
        async let second: Void = model.refresh()
        _ = await (first, second)
        _ = try await eventually {
            let open = await server.calls(to: "zcode-agent.subscribeSessionsIndexV4").count
                - server.calls(to: "zcode-agent.unsubscribeSessionsIndexV4").count
            return open == 1 ? true : nil
        }
        _ = try await eventually { await server.listenerCount(indexEvent) == 1 ? true : nil }
        try await Task.sleep(for: .milliseconds(100))
        let open = await server.calls(to: "zcode-agent.subscribeSessionsIndexV4").count
            - server.calls(to: "zcode-agent.unsubscribeSessionsIndexV4").count
        #expect(open == 1)
        #expect(await server.listenerCount(indexEvent) == 1)
    }

    @Test func brouillonOublieApresSuppression() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                "revisionAtDecision": .number(0),
                "result": .object(["type": .string("createSession"), "sessionId": .string("sess_neuve")]),
            ])
        }
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        _ = try await model.createSession(builder: CommandBuilder(clientId: "client-test"))
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON("sess_neuve")))
        _ = try await eventually { model.sessions.count == 2 ? true : nil }
        await server.emit(indexEvent, try indexDelta([.object(["op": .string("session.removed"), "sessionId": .string("sess_neuve")])], fromSeq: 2))
        _ = try await eventually { model.sessions.count == 1 ? true : nil }      // supprimée depuis l'interface web
        #expect(model.drafts.isEmpty)
    }

    @Test func suppressionDUneSession() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(0)])
        }
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        try await model.deleteSession("sess_a", builder: CommandBuilder(clientId: "client-test"))
        let envelope = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"])
        #expect(envelope["type"] == .string("deleteSession"))
        #expect(envelope["sessionId"] == .string("sess_a"))
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("proto.sessionNotFound"), "revisionAtDecision": .number(0)])
        }
        await #expect(throws: SessionsError.deleteRejected("proto.sessionNotFound")) {
            try await model.deleteSession("sess_b", builder: CommandBuilder(clientId: "client-test"))
        }
    }

    @Test func renommerUneSession() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(4)])
        }
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        try await model.renameSession("sess_a", title: "Refonte", builder: CommandBuilder(clientId: "client-test"))
        let envelope = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"])
        #expect(envelope["type"] == .string("renameSession"))
        #expect(envelope["sessionId"] == .string("sess_a"))
        #expect(envelope["payload"] == .object(["title": .string("Refonte")]))
        #expect(envelope["baseRevision"] == nil)                                 // pas CAS
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("proto.sessionNotFound"), "revisionAtDecision": .number(0)])
        }
        await #expect(throws: SessionsError.renameRejected("proto.sessionNotFound")) {
            try await model.renameSession("sess_b", title: "X", builder: CommandBuilder(clientId: "client-test"))
        }
    }

    // MARK: - Archivage

    /// Modèle prêt avec `sess_a` publiée dans l'index (la trame initiale réelle ne contient que la session PONG).
    private func startedModel(_ server: FakeZCodeServer, store: ArchiveStore = ArchiveStore(),
                              cache: ConversationCache? = nil,
                              now: @escaping @Sendable () -> Date = Date.init) async throws -> SessionsModel {
        let model = makeModel(ServerQueue([server]), archiveStore: store, cache: cache, now: now)
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON("sess_a")))
        _ = try await eventually { model.sessions.contains { $0.sessionId == "sess_a" } ? true : nil }
        return model
    }

    @Test func archivageFermePuisArchiveEtCache() async throws {
        let server = try await taskIndexServer(archived: [archivedTaskJSON("sess_a")])
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(0)])
        }
        let clock = Date(timeIntervalSince1970: 1_791_900_000)
        let model = try await startedModel(server, now: { clock })
        try await model.archive("sess_a", builder: CommandBuilder(clientId: "client-test"))
        let close = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"])
        #expect(close["type"] == .string("deleteSession"))                          // fermée sur l'hôte…
        let archiveCall = try #require(await server.calls(to: "zcode-task.archiveTask").first)
        #expect(archiveCall["taskId"] == .string("sess_a"))                         // …puis archivée
        #expect(archiveCall["workspacePath"] == .string(testWorkspacePath))
        #expect(model.sessions.contains { $0.sessionId == "sess_a" })               // toujours dans l'index…
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" } == false) // …mais cachée
        let archived = try #require(model.archived.first { $0.sessionId == "sess_a" })
        #expect(archived.archivedAt == clock)                                       // délai des 30 jours ancré
    }

    @Test func archivageCacheToutDeSuite() async throws {
        // Sans confirmation, la ligne doit disparaître dès le geste, avant la réponse de l'hôte.
        let server = try await taskIndexServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Thread.sleep(forTimeInterval: 0.3)                                      // hôte lent
            return .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                            "revisionAtDecision": .number(0)])
        }
        let model = try await startedModel(server)
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" })
        let archivedJSON = archivedTaskJSON("sess_a")
        await server.on("zcode-task.listArchivedTasks") { _ in .array([archivedJSON]) }   // archivée une fois l'appel fait
        let archiving = Task { try await model.archive("sess_a", builder: CommandBuilder(clientId: "client-test")) }
        _ = try await eventually(timeout: .milliseconds(200)) {
            model.visibleSessions.contains { $0.sessionId == "sess_a" } ? nil : true
        }
        try await archiving.value
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" } == false)
    }

    @Test func archivageRefuseRemetLaLigne() async throws {
        let server = try await taskIndexServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(0)])
        }
        await server.on("zcode-task.archiveTask") { _ in throw FakeRemoteError("index des tâches indisponible") }
        let model = try await startedModel(server)
        await #expect(throws: SessionsError.self) {
            try await model.archive("sess_a", builder: CommandBuilder(clientId: "client-test"))
        }
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" })       // de retour dans la liste
    }

    @Test func archivageDUneSessionNonChargeeSurLhote() async throws {
        let server = try await taskIndexServer(archived: [archivedTaskJSON("sess_a")])
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("proto.sessionNotFound"), "revisionAtDecision": .number(0)])
        }
        let model = try await startedModel(server)
        try await model.archive("sess_a", builder: CommandBuilder(clientId: "client-test"))  // pas d'erreur
        _ = try #require(await server.calls(to: "zcode-task.archiveTask").first)             // archivée quand même
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" } == false)
    }

    @Test func brouillonFermeSansArchivage() async throws {
        let server = try await taskIndexServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                "revisionAtDecision": .number(0),
                "result": .object(["type": .string("createSession"), "sessionId": .string("sess_neuve")]),
            ])
        }
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        _ = try await model.createSession(builder: CommandBuilder(clientId: "client-test"))
        try await model.archive("sess_neuve", builder: CommandBuilder(clientId: "client-test"))
        #expect(await server.calls(to: "zcode-task.archiveTask").isEmpty)          // rien à archiver
        #expect(model.drafts.isEmpty)                                              // fermée tout de même
    }

    @Test func archiveeAilleursDisparaitDeLaListe() async throws {
        // L'entrée sans `taskId` est ignorée ; `sess_a` (archivée dans l'interface web) est cachée.
        let server = try await taskIndexServer(archived: [.object(["title": .string("cassée")]), archivedTaskJSON("sess_a")])
        let clock = Date(timeIntervalSince1970: 1_791_900_000)
        let store = ArchiveStore()
        let model = try await startedModel(server, store: store, now: { clock })
        _ = try await eventually { model.visibleSessions.contains { $0.sessionId == "sess_a" } == false ? true : nil }
        #expect(model.sessions.contains { $0.sessionId == "sess_a" })
        _ = try await eventually { model.archived.count == 1 ? true : nil }
        #expect(model.archived.first?.archivedAt == clock)       // première vue : date du délai
        #expect(store.archivedAt(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_a") == clock)
    }

    @Test func desarchivageRevientDansLaListe() async throws {
        let server = try await taskIndexServer(archived: [archivedTaskJSON("sess_a")])
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(0)])
        }
        let store = ArchiveStore()
        let model = try await startedModel(server, store: store)
        try await model.archive("sess_a", builder: CommandBuilder(clientId: "client-test"))
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }        // désarchivée côté hôte
        try await model.unarchive("sess_a")
        let call = try #require(await server.calls(to: "zcode-task.unarchiveTask").first)
        #expect(call["taskId"] == .string("sess_a"))
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" })
        #expect(model.archived.isEmpty)
        #expect(store.archivedAt(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_a") == nil)
    }

    @Test func suppressionDefinitiveManuelle() async throws {
        let server = try await taskIndexServer(archived: [archivedTaskJSON("sess_a")])
        let model = try await startedModel(server)
        _ = try await eventually { model.visibleSessions.contains { $0.sessionId == "sess_a" } == false ? true : nil }
        try await model.deleteArchivedNow("sess_a")
        let call = try #require(await server.calls(to: "zcode-task.deleteArchivedTask").first)
        #expect(call["taskId"] == .string("sess_a"))
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([.string("sess_a")]) }
        await model.refreshArchived()
        _ = try await eventually { model.archived.isEmpty ? true : nil }
        #expect(model.visibleSessions.contains { $0.sessionId == "sess_a" } == false) // cachée par le tombeau
        #expect(model.hiddenIds.contains("sess_a"))
    }

    func cachedSnapshot() throws -> ConversationSnapshot {
        try ConversationSnapshot(json: #require(conversationRecord("004")["frame"]?["payload"]?["snapshot"]))
    }

    /// Suppression définitive : la copie hors ligne de la conversation part aussi.
    @Test func suppressionDefinitiveEffaceLaCopieHorsLigne() async throws {
        let server = try await taskIndexServer(archived: [archivedTaskJSON("sess_a")])
        let cache = ConversationCache()
        let model = try await startedModel(server, cache: cache)
        await cache.saveConversation(try cachedSnapshot(), key: model.key("sess_a"), savedAt: Date())
        await cache.saveConversation(try cachedSnapshot(), key: model.key(pongSession), savedAt: Date())
        try await model.deleteArchivedNow("sess_a")
        #expect(await cache.conversation(model.key("sess_a")) == nil)
        #expect(await cache.conversation(model.key(pongSession)) != nil)
    }

    @Test func purgeEffaceLaCopieHorsLigne() async throws {
        let server = try await taskIndexServer()
        let store = ArchiveStore()
        let cache = ConversationCache()
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        store.record(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_a",
                     at: now.addingTimeInterval(-31 * 24 * 3600))
        store.record(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_b",
                     at: now.addingTimeInterval(-29 * 24 * 3600))
        let model = makeModel(ServerQueue([server]), archiveStore: store, cache: cache, now: { now })
        await cache.saveConversation(try cachedSnapshot(), key: model.key("sess_a"), savedAt: now)
        await cache.saveConversation(try cachedSnapshot(), key: model.key("sess_b"), savedAt: now)
        await model.start()
        _ = try await eventually { await cache.conversation(model.key("sess_a")) == nil ? true : nil }
        #expect(await cache.conversation(model.key("sess_b")) != nil)               // pas encore expirée
    }

    @Test func purgeApresTrenteJours() async throws {
        let server = try await taskIndexServer()
        let store = ArchiveStore()
        store.record(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_a",
                     at: Date(timeIntervalSince1970: 1_791_900_000).addingTimeInterval(-31 * 24 * 3600))
        store.record(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_b",
                     at: Date(timeIntervalSince1970: 1_791_900_000).addingTimeInterval(-29 * 24 * 3600))
        let model = makeModel(ServerQueue([server]), archiveStore: store,
                              now: { Date(timeIntervalSince1970: 1_791_900_000) })
        await model.start()
        _ = try await eventually { await server.calls(to: "zcode-task.deleteArchivedTask").count == 1 ? true : nil }
        let call = try #require(await server.calls(to: "zcode-task.deleteArchivedTask").first)
        #expect(call["taskId"] == .string("sess_a"))                          // seulement la plus vieille
        #expect(store.archivedAt(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_a") == nil)
        #expect(store.archivedAt(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_b") != nil)
    }

    @Test func purgeSansEntreeExpireeNAppelleRien() async throws {
        let server = try await taskIndexServer()
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.calls(to: "zcode-task.deleteArchivedTask").isEmpty)
    }

    @Test func nonLuApresUneActiviteSurLHote() async throws {
        let server = try await sessionsServer()
        let model = makeModel(ServerQueue([server]))
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        let pong = try await eventually { model.phase == .ready ? model.sessions.first : nil }
        #expect(!model.isUnread(pong))                                            // premier chargement : lu
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON(pongSession, title: "PONG")))
        let moved = try await eventually {
            model.sessions.first?.lastActivityAt == 1_791_890_000_000 ? model.sessions.first : nil
        }
        #expect(model.isUnread(moved))                                            // activité postérieure
    }

    @Test func menageDesSessionsDisparues() async throws {
        let server = try await sessionsServer()
        let seen = SeenStore()
        let gone = SessionKey(hostId: testHost.id, workspace: testWorkspacePath, sessionId: "sess_partie")
        let kept = SessionKey(hostId: testHost.id, workspace: testWorkspacePath, sessionId: pongSession)
        seen.markSeen(gone, at: 1)
        seen.markSeen(kept, at: 1)
        let model = makeModel(ServerQueue([server]), seenStore: seen)
        await model.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(seen.lastSeen(gone) == nil)
        #expect(seen.lastSeen(kept) == 1)
    }
}
