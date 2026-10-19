import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct SessionsOfflineTests {
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = Date(timeIntervalSince1970: 1_800_000_500)

    func model(_ servers: ServerQueue, cache: ConversationCache) -> SessionsModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        return SessionsModel(connection: connection, workspace: testWorkspacePath, cache: cache, now: { [clock] in clock })
    }

    func realIndex() throws -> SessionsIndex {
        try SessionsIndex(json: #require(initialIndexFrame()["frame"]?["payload"]?["snapshot"]))
    }

    @Test func listeCopiéeQuandInjoignable() async throws {
        let cache = ConversationCache()
        let index = try realIndex()
        await cache.saveSessions(index, hidden: [], hostId: testHost.id, workspace: testWorkspacePath, savedAt: saved)
        let sessions = model(ServerQueue([]), cache: cache)
        await sessions.start()
        guard case .failed = sessions.phase else { Issue.record("échec attendu"); return }
        #expect(sessions.offlineCopyDate == saved)
        #expect(sessions.isLocked)
        #expect(sessions.sessions.map(\.sessionId) == index.byRecentActivity.map(\.sessionId))
    }

    @Test func listeVivanteÉcriteÀLArrêtSansSessionsCachées() async throws {
        let cache = ConversationCache()
        let server = try await sessionsServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let sessions = model(ServerQueue([server]), cache: cache)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        await sessions.stop()
        let copy = try #require(await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath))
        #expect(copy.savedAt == clock)
        #expect(copy.value.sessions.count == sessions.index?.sessions.count)
        #expect(sessions.offlineCopyDate == nil)
    }

    @Test func listeCopiéeSansSessionsCachées() async throws {
        let cache = ConversationCache()
        let index = try realIndex()
        let hidden = try #require(index.sessions.first?.sessionId)
        await cache.saveSessions(index, hidden: [hidden], hostId: testHost.id, workspace: testWorkspacePath, savedAt: saved)
        let sessions = model(ServerQueue([]), cache: cache)
        await sessions.start()
        #expect(!sessions.sessions.contains { $0.sessionId == hidden })
    }

    @Test func copieNeTouchePasAuxÉtatsLocaux() async throws {
        let cache = ConversationCache()
        await cache.saveSessions(try realIndex(), hidden: [], hostId: testHost.id, workspace: testWorkspacePath, savedAt: saved)
        let seen = SeenStore()
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([])))
        let sessions = SessionsModel(connection: connection, workspace: testWorkspacePath, seenStore: seen, cache: cache)
        await sessions.start()
        let summary = try #require(sessions.sessions.first)
        // Aucune base posée par la copie : la première pose (ici 0) est donc acceptée, et la session a bougé depuis.
        seen.establishBaseline(hostId: testHost.id, workspace: testWorkspacePath, lastActivities: [0])
        #expect(summary.lastActivityAt > 0)
        #expect(sessions.isUnread(summary))
    }

    @Test func listeFigéeParCoupureSansRelanceRestante() async throws {
        let cache = ConversationCache()
        let server = try await sessionsServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let sessions = model(ServerQueue([server]), cache: cache)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        server.transport.finish()      // plus aucun serveur ensuite : la relance échoue sans agent
        _ = try await eventually { sessions.offlineCopyDate != nil ? true : nil }
        #expect(sessions.offlineCopyDate == clock)
        #expect(sessions.isLocked)
        #expect(!sessions.sessions.isEmpty)
        _ = try await eventually { await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath)?.savedAt == clock ? true : nil }
    }

    /// Relances automatiques épuisées : chaque nouvel abonnement tombe aussitôt, la dernière coupure fige la liste.
    @Test func relancesÉpuiséesFigentLaListeVivante() async throws {
        let first = try await sessionsServer()
        await first.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await first.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        var servers = [first]
        for _ in 0..<SessionsModel.maxAutomaticRestarts {
            let server = try await sessionsServer()
            let ack = try Fixtures.recorded("v3.15.1/handshake-sessions/003-result-zcode-agent.subscribeSessionsIndexV4.json")
            await server.on("zcode-agent.subscribeSessionsIndexV4") { [server] _ in
                // Le serveur (acteur) répond avant de lire `listenerCount` : l'accusé précède toujours la fin du flux.
                Task {
                    _ = try? await eventually { await server.listenerCount(indexEvent) > 0 ? true : nil }
                    server.transport.finish()
                }
                return ack
            }
            servers.append(server)
        }
        let queue = ServerQueue(servers)
        let cache = ConversationCache()
        let sessions = model(queue, cache: cache)
        await sessions.start()
        try await emitWhenListening(first, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        first.transport.finish()
        _ = try await eventually { sessions.offlineCopyDate != nil ? true : nil }
        #expect(queue.opened == SessionsModel.maxAutomaticRestarts + 1)
        #expect(sessions.phase == .failed(TopicFeedFailure.connectionLost))   // figé par `handle(.failed)`, pas par `start`
        #expect(sessions.offlineCopyDate == clock)
        _ = try await eventually { await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath)?.savedAt == clock ? true : nil }
    }

    @Test func étatVivantRemetOfflineCopyDateÀNil() async throws {
        let cache = ConversationCache()
        await cache.saveSessions(try realIndex(), hidden: [], hostId: testHost.id, workspace: testWorkspacePath, savedAt: saved)
        let server = try await sessionsServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let sessions = model(ServerQueue([server]), cache: cache)
        await sessions.start()
        #expect(sessions.offlineCopyDate == saved)
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.offlineCopyDate == nil ? true : nil }
        #expect(!sessions.isLocked)
    }

    @Test func détachéNeRéécritRienÀLArrêt() async throws {
        let cache = ConversationCache()
        let server = try await sessionsServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let sessions = model(ServerQueue([server]), cache: cache)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        sessions.detachOfflineCache()
        await sessions.stop()
        #expect(await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath) == nil)
    }

    @Test func arrêtSurCopieNeRéécritPas() async throws {
        let cache = ConversationCache()
        await cache.saveSessions(try realIndex(), hidden: [], hostId: testHost.id, workspace: testWorkspacePath, savedAt: saved)
        let sessions = model(ServerQueue([]), cache: cache)
        await sessions.start()
        #expect(sessions.offlineCopyDate == saved)
        await sessions.stop()
        let copy = try #require(await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath))
        #expect(copy.savedAt == saved)
    }

    @Test func sessionArchivéeAbsenteDeLaCopieÉcrite() async throws {
        let cache = ConversationCache()
        let archivedId = try #require(realIndex().sessions.first?.sessionId)
        let server = try await sessionsServer()
        let task = JSONValue.object([
            "taskId": .string(archivedId), "title": .string("Archivée"), "workspacePath": .string(testWorkspacePath),
            "traceId": .string("trace_1"), "createdAt": .number(1_791_880_000_000), "updatedAt": .number(1_791_890_000_000),
            "mode": .string("chat"),
        ])
        await server.on("zcode-task.listArchivedTasks") { _ in .array([task]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let sessions = model(ServerQueue([server]), cache: cache)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        #expect(sessions.hiddenIds.contains(archivedId))
        await sessions.stop()
        let copy = try #require(await cache.sessions(hostId: testHost.id, workspace: testWorkspacePath))
        #expect(!copy.value.sessions.contains { $0.sessionId == archivedId })
        #expect(copy.value.sessions.count == (sessions.index?.sessions.count ?? 0) - 1)
    }
}
