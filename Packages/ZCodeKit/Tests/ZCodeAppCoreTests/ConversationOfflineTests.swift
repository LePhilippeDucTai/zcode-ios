import Foundation
import Synchronization
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationOfflineTests {
    let key = SessionKey(hostId: testHost.id, workspace: testWorkspacePath, sessionId: pongSession)
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = Date(timeIntervalSince1970: 1_800_000_500)

    func cachedSnapshot() throws -> ConversationSnapshot {
        try ConversationSnapshot(json: #require(conversationRecord("004")["frame"]?["payload"]?["snapshot"]))
    }

    @Test func hôteInjoignableGardeLaCopie() async throws {
        let cache = ConversationCache()
        await cache.saveConversation(try cachedSnapshot(), key: key, savedAt: saved)
        let model = makeConversation(ServerQueue([]), cache: cache)   // aucun serveur : injoignable
        await model.start()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        #expect(model.offlineCopyDate == saved)
        #expect(model.turnCount == 1)
        #expect(model.isLocked)
        #expect(model.forkableRowIds.isEmpty)
        #expect(model.retryEntryId == nil)
        #expect(model.hasOlderRows == false)
        #expect(!model.canPauseGoal && !model.canResumeGoal)
    }

    @Test func copieAffichéePendantLaConnexion() async throws {
        let cache = ConversationCache()
        await cache.saveConversation(try cachedSnapshot(), key: key, savedAt: saved)
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]), cache: cache)
        let starting = Task { await model.start() }
        _ = try await eventually { model.offlineCopyDate == saved && model.phase == .loading ? true : nil }
        #expect(model.turnCount == 1)
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.offlineCopyDate == nil)
        await starting.value
    }

    @Test func stopÉcritLaCopieVivante() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]), cache: cache, now: { [clock] in clock })
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        await model.stop()
        let copy = try #require(await cache.conversation(key))
        #expect(copy.savedAt == clock)
        #expect(copy.value.rows.map(\.rowId) == [1, 2, 3, 4])
    }

    @Test func stopNÉcritPasUneCopie() async throws {
        let cache = ConversationCache()
        await cache.saveConversation(try cachedSnapshot(), key: key, savedAt: saved)
        let model = makeConversation(ServerQueue([]), cache: cache, now: { [clock] in clock })
        await model.start()
        await model.stop()
        #expect(await cache.conversation(key)?.savedAt == saved)
    }

    @Test func coupureDurableFigeLÉtatVivant() async throws {
        let server = try await conversationServer()
        let cache = ConversationCache()
        let model = makeConversation(ServerQueue([server]), cache: cache, now: { [clock] in clock })
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        server.transport.finish()                                       // plus aucun serveur ensuite
        _ = try await eventually { model.offlineCopyDate != nil ? true : nil }
        #expect(model.offlineCopyDate == clock)                         // date de la dernière mise à jour vivante
        #expect(model.turnCount == 1)
        _ = try await eventually { await cache.conversation(key)?.savedAt == clock ? true : nil }   // écrit aussitôt
    }

    @Test func sansCopieRienNeChange() async throws {
        let model = makeConversation(ServerQueue([]), cache: ConversationCache())
        await model.start()
        #expect(model.offlineCopyDate == nil)
        #expect(model.snapshot == nil)
    }

    @Test func fluxVivantRemplaceLaCopie() async throws {
        let cache = ConversationCache()
        await cache.saveConversation(try cachedSnapshot(), key: key, savedAt: saved)
        let server = try await conversationServer()
        let ack = try conversationRecord("003")
        await server.on("zcode-agent.subscribeConversationV4") { _ in throw CheckError("indisponible") }
        let model = makeConversation(ServerQueue([server]), cache: cache)
        await model.start()
        #expect(model.offlineCopyDate == saved)
        await server.on("zcode-agent.subscribeConversationV4") { _ in ack }
        await model.refresh()                                           // « Réessayer »
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.offlineCopyDate == nil)
        #expect(model.finishedTurns == 0 && model.newInteractionAlerts == 0)
        #expect(model.snapshot?.rows.map(\.rowId) == [1, 2, 3, 4])
    }

    @Test func stopAprèsDétachementNÉcritRien() async throws {
        let cache = ConversationCache()
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]), cache: cache)
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        model.detachOfflineCache()                                      // copie effacée par l'app (archivage)
        await model.stop()
        #expect(await cache.conversation(key) == nil)
    }

    /// Relances automatiques épuisées : chaque nouvel abonnement tombe aussitôt, la dernière coupure fige l'état.
    @Test func relancesÉpuiséesFigentLÉtatVivant() async throws {
        let first = try await conversationServer()
        var servers = [first]
        for _ in 0..<ConversationModel.maxAutomaticRestarts {
            let server = try await conversationServer()
            let ack = try conversationRecord("003")
            await server.on("zcode-agent.subscribeConversationV4") { [server] _ in
                // Coupure juste après l'accusé : l'abonnement réussit, puis le flux s'arrête (`connectionLost`).
                // Le serveur (acteur) répond avant de lire `listenerCount` : l'accusé précède toujours la fin du flux.
                Task {
                    _ = try? await eventually { await server.listenerCount(conversationEvent) > 0 ? true : nil }
                    server.transport.finish()
                }
                return ack
            }
            servers.append(server)
        }
        let queue = ServerQueue(servers)
        let cache = ConversationCache()
        let model = makeConversation(queue, cache: cache, now: { [clock] in clock })
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        first.transport.finish()
        _ = try await eventually { model.offlineCopyDate != nil ? true : nil }
        #expect(queue.opened == ConversationModel.maxAutomaticRestarts + 1)
        #expect(model.phase == .failed(TopicFeedFailure.connectionLost))   // figé par `handle(.failed)`, pas par `begin`
        #expect(model.offlineCopyDate == clock)
        #expect(model.turnCount == 1)
        _ = try await eventually { await cache.conversation(key)?.savedAt == clock ? true : nil }
    }

    /// Fil d'un sous-agent (lecture seule, sans cache) : l'historique reste paginable.
    @Test func filDeSousAgentGardeLaPagination() async throws {
        let server = try await conversationServer()
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, readOnly: true)
        await model.start()
        try await emitConversation(server, initialConversationFrame { snapshot in
            // Fenêtre réduite aux deux dernières lignes : les lignes 1 et 2 restent à charger.
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array((rows["window"]?.arrayValue ?? []).filter { ($0["rowId"]?.numberValue ?? 0) >= 3 })
            snapshot["rows"] = .object(rows)
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.isLocked)
        #expect(model.offlineCopyDate == nil)
        #expect(model.hasOlderRows)
    }

    /// Fil d'un sous-agent coupé de l'hôte : il ne devient pas une copie (ni bandeau gris, ni pagination bloquée).
    @Test func filDeSousAgentNeDevientPasUneCopie() async throws {
        let server = try await conversationServer()
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, readOnly: true)
        await model.start()
        try await emitConversation(server, initialConversationFrame { snapshot in
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array((rows["window"]?.arrayValue ?? []).filter { ($0["rowId"]?.numberValue ?? 0) >= 3 })
            snapshot["rows"] = .object(rows)
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.hasOlderRows)
        server.transport.finish()                                       // plus aucun serveur ensuite
        // Seconde panne : la relance automatique ne trouve plus d'hôte (la première, `connectionLost`, la précède).
        _ = try await eventually {
            if case .failed(let reason) = model.phase, reason != TopicFeedFailure.connectionLost { return true }
            return nil
        }
        #expect(model.offlineCopyDate == nil)
        #expect(model.hasOlderRows)
    }

    /// `stop()` passe à `.idle` avant d'écrire la copie : un `startIfNeeded` arrivé pendant l'écriture relance
    /// l'abonnement au lieu de croire la conversation encore prête.
    @Test func reprisePendantLÉcritureDeLArrêtRelanceLAbonnement() async throws {
        let storage = GatedOfflineStorage()
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]), cache: ConversationCache(storage: storage))
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        storage.close()
        let stopping = Task { await model.stop() }
        _ = try await eventually { storage.writing ? true : nil }       // écriture de l'arrêt en cours, bloquée
        await model.startIfNeeded()
        storage.open()
        await stopping.value
        #expect(await server.calls(to: "zcode-agent.subscribeConversationV4").count == 2)
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
    }
}

/// Stockage dont l'écriture attend `open()` (au plus 5 s) : simule une écriture lente du cache.
final class GatedOfflineStorage: OfflineCacheStorage {
    private let inner = InMemoryOfflineCacheStorage()
    private let gate = DispatchSemaphore(value: 0)
    private let state = Mutex((closed: false, writing: false))

    var writing: Bool { state.withLock { $0.writing } }
    func close() { state.withLock { $0.closed = true } }
    func open() { gate.signal() }

    func read(_ name: String) -> Data? { inner.read(name) }
    func write(_ data: Data, name: String) {
        if state.withLock({ $0.closed }) {
            state.withLock { $0.writing = true }
            _ = gate.wait(timeout: .now() + 5)
            state.withLock { $0 = (false, false) }
        }
        inner.write(data, name: name)
    }
    func remove(_ name: String) { inner.remove(name) }
    func removeAll() { inner.removeAll() }
}
