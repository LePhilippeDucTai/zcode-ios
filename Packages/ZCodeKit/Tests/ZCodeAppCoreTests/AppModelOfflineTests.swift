import Foundation
import Synchronization
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct AppModelOfflineTests {
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = Date(timeIntervalSince1970: 1_800_000_500)

    func makeApp(_ servers: ServerQueue, cache: ConversationCache,
                 now: (@Sendable () -> Date)? = nil) throws -> (AppModel, ZCodeAppCore.Host) {
        let store = HostStore(persistence: InMemoryHostPersistence(), tokens: InMemoryTokenStore())
        let host = try store.add(name: "Mac", url: "mac.ts.net", token: "jeton")
        let clock = clock
        return (AppModel(hostStore: store, dependencies: makeDependencies(servers: servers),
                         offlineCache: cache, now: now ?? { clock }), host)
    }

    func key(_ host: ZCodeAppCore.Host, sessionId: String = pongSession) -> SessionKey {
        SessionKey(hostId: host.id, workspace: testWorkspacePath, sessionId: sessionId)
    }

    func cachedSnapshot() throws -> ConversationSnapshot {
        try ConversationSnapshot(json: #require(conversationRecord("004")["frame"]?["payload"]?["snapshot"]))
    }

    /// Serveur de conversation qui accepte aussi la fermeture de la session et son archivage sur l'hôte.
    func archivingServer() async throws -> FakeZCodeServer {
        let server = try await conversationServer()
        await server.on("zcode-task.listArchivedTasks") { _ in .array([]) }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        await server.on("zcode-task.archiveTask") { _ in .object(["taskId": .string("ok")]) }
        return server
    }

    /// Conversation PONG ouverte et prête (sans `stop()`).
    func openConversation(_ app: AppModel, _ host: ZCodeAppCore.Host, _ server: FakeZCodeServer,
                          readOnly: Bool = false) async throws -> ConversationModel {
        let conversation = app.conversation(for: host, workspace: testWorkspacePath, sessionId: pongSession,
                                            readOnly: readOnly)
        await conversation.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { conversation.phase == .ready ? true : nil }
        return conversation
    }

    @Test func filDeSousAgentSansCopie() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server, readOnly: true)
        await conversation.stop()
        #expect(await cache.conversation(key(host)) == nil)
        await app.saveOfflineCopies()
        #expect(await cache.conversation(key(host)) == nil)
    }

    @Test func conversationOuverteEcritSaCopieALArret() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server)
        await conversation.stop()
        #expect(await cache.conversation(key(host))?.savedAt == clock)     // horloge de l'app passée au modèle
    }

    @Test func archivageEffaceLaCopie() async throws {
        let cache = ConversationCache()
        let server = try await archivingServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server)
        await conversation.stop()
        #expect(await cache.conversation(key(host)) != nil)
        try await app.archiveSession(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        #expect(await cache.conversation(key(host)) == nil)
    }

    /// L'écran se ferme après l'archivage : son `stop()` tardif ne doit pas ressusciter la copie.
    @Test func fermetureTardiveApresArchivageNeRecreePasLaCopie() async throws {
        let cache = ConversationCache()
        let server = try await archivingServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server)
        try await app.archiveSession(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        await conversation.stop()
        #expect(await cache.conversation(key(host)) == nil)
    }

    @Test func suppressionEffaceLaCopieSansRecreationTardive() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server)
        await conversation.stop()
        #expect(await cache.conversation(key(host)) != nil)
        try await app.deleteSession(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        #expect(await cache.conversation(key(host)) == nil)
        await conversation.stop()
        #expect(await cache.conversation(key(host)) == nil)
    }

    @Test func suppressionDHôteVideSonCache() async throws {
        let cache = ConversationCache()
        let (app, host) = try makeApp(ServerQueue([]), cache: cache)
        await cache.saveConversation(try cachedSnapshot(), key: key(host), savedAt: saved)
        #expect(await cache.bytes(hostId: host.id) > 0)
        await app.removeHost(host.id)
        #expect(await cache.bytes(hostId: host.id) == 0)
    }

    /// Hôte supprimé alors qu'un écran est ouvert : l'arrêt des modèles ne réécrit rien.
    @Test func suppressionDHôteNeLaisseAucuneCopieTardive() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let conversation = try await openConversation(app, host, server)
        await app.removeHost(host.id)
        await conversation.stop()
        #expect(await cache.bytes(hostId: host.id) == 0)
    }

    /// Même garantie pour la liste des sessions d'un hôte supprimé.
    @Test func suppressionDHôteNeLaisseAucuneListeTardive() async throws {
        let cache = ConversationCache()
        let server = try await sessionsAndConversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        await app.removeHost(host.id)
        await sessions.stop()
        #expect(await cache.bytes(hostId: host.id) == 0)
    }

    /// Simple changement d'adresse ou de token : la copie reste (l'arrêt des modèles l'écrit).
    @Test func changementDAdresseGardeLaCopie() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache)
        _ = try await openConversation(app, host, server)
        await app.hostDidChange(host.id)
        #expect(await cache.conversation(key(host)) != nil)
    }

    @Test func viderLeCacheDUnHôte() async throws {
        let cache = ConversationCache()
        let (app, first) = try makeApp(ServerQueue([]), cache: cache)
        let second = try app.hostStore.add(name: "Steam", url: "steam.ts.net", token: "jeton-b")
        await cache.saveConversation(try cachedSnapshot(), key: key(first), savedAt: saved)
        await cache.saveConversation(try cachedSnapshot(), key: key(second), savedAt: saved)
        #expect(await app.offlineCacheBytes(for: first) > 0)
        await app.clearOfflineCache(for: first)
        #expect(await app.offlineCacheBytes(for: first) == 0)
        #expect(await app.offlineCacheBytes(for: second) > 0)
    }

    /// Conversation fermée mais gardée en mémoire : le passage en arrière-plan ne la redate pas.
    @Test func conversationFerméeGardeSaDateEnArrièrePlan() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let time = Mutex(clock)
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache, now: { time.withLock { $0 } })
        let conversation = try await openConversation(app, host, server)
        await conversation.stop()
        #expect(await cache.conversation(key(host))?.savedAt == clock)
        time.withLock { $0 = clock.addingTimeInterval(3600) }
        await app.saveOfflineCopies()
        #expect(await cache.conversation(key(host))?.savedAt == clock)
    }

    /// Conversation et liste vivantes : datées du passage en arrière-plan, pas de leur dernier état reçu.
    @Test func arrièrePlanÉcritLesCopiesOuvertes() async throws {
        let cache = ConversationCache()
        let server = try await sessionsAndConversationServer()
        let time = Mutex(clock)
        let later = clock.addingTimeInterval(3600)
        let (app, host) = try makeApp(ServerQueue([server]), cache: cache, now: { time.withLock { $0 } })
        _ = try await openConversation(app, host, server)
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        #expect(await cache.conversation(key(host)) == nil)                // rien d'écrit avant l'arrière-plan
        #expect(await cache.sessions(hostId: host.id, workspace: testWorkspacePath) == nil)
        time.withLock { $0 = later }
        await app.saveOfflineCopies()
        #expect(await cache.conversation(key(host))?.savedAt == later)
        #expect(await cache.sessions(hostId: host.id, workspace: testWorkspacePath)?.savedAt == later)
    }

    func sessionsAndConversationServer() async throws -> FakeZCodeServer {
        let server = try await conversationServer()
        let ack = try Fixtures.recorded("v3.15.1/handshake-sessions/003-result-zcode-agent.subscribeSessionsIndexV4.json")
        await server.on("zcode-agent.subscribeSessionsIndexV4") { _ in ack }
        await server.on("zcode-agent.unsubscribeSessionsIndexV4") { _ in .null }
        return server
    }
}
