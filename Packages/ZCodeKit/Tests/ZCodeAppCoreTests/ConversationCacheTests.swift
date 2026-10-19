import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ConversationCacheTests {
    let host = UUID()
    func key(_ id: String, host: UUID? = nil) -> SessionKey {
        SessionKey(hostId: host ?? self.host, workspace: "/w", sessionId: id)
    }
    func snapshot() throws -> ConversationSnapshot {
        let wire = try #require(try Fixtures.records(in: "v3.15.1/send-text").first { $0.file.hasPrefix("004") }).value
        return try ConversationSnapshot(json: #require(wire["frame"]?["payload"]?["snapshot"]))
    }
    func index() throws -> SessionsIndex {
        let wire = try Fixtures.recorded("v3.15.1/handshake-sessions/004-event-zcode-agent.onDynamicSessionsIndexFrame.json")
        return try SessionsIndex(json: #require(wire["frame"]?["payload"]?["snapshot"]))
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func conversationRelue() async throws {
        let cache = ConversationCache()
        let original = try snapshot()
        await cache.saveConversation(original, key: key("s1"), savedAt: t0)
        let copy = try #require(await cache.conversation(key("s1")))
        #expect(copy.value == original)
        #expect(copy.savedAt == t0)
        #expect(await cache.conversation(key("autre")) == nil)
    }

    @Test func relueParUnNouveauCacheSurLeMêmeStockage() async throws {
        let storage = InMemoryOfflineCacheStorage()
        await ConversationCache(storage: storage).saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        #expect(await ConversationCache(storage: storage).conversation(key("s1"))?.savedAt == t0)
    }

    @Test func listeRelueSansSessionsCachées() async throws {
        let cache = ConversationCache()
        let index = try index()
        let hidden = Set(index.sessions.prefix(1).map(\.sessionId))
        await cache.saveSessions(index, hidden: hidden, hostId: host, workspace: "/w", savedAt: t0)
        let copy = try #require(await cache.sessions(hostId: host, workspace: "/w"))
        #expect(copy.value.sessions.count == index.sessions.count - hidden.count)
    }

    @Test func vingtConversationsParHôte() async throws {
        let cache = ConversationCache(maxConversationsPerHost: 2)
        let other = UUID()
        for (i, id) in ["a", "b", "c"].enumerated() {
            await cache.saveConversation(try snapshot(), key: key(id), savedAt: t0.addingTimeInterval(Double(i)))
        }
        await cache.saveConversation(try snapshot(), key: key("x", host: other), savedAt: t0)
        await cache.saveSessions(try index(), hidden: [], hostId: host, workspace: "/w", savedAt: t0)
        #expect(await cache.conversation(key("a")) == nil)                  // la plus ancienne
        #expect(await cache.conversation(key("b")) != nil)
        #expect(await cache.conversation(key("c")) != nil)
        #expect(await cache.conversation(key("x", host: other)) != nil)    // autre hôte : non compté
        #expect(await cache.sessions(hostId: host, workspace: "/w") != nil) // listes : non comptées
    }

    @Test func bornéEnOctets() async throws {
        let one = try JSONEncoder().encode(try snapshot().offlineJSON(keepingLast: 60)).count
        let cache = ConversationCache(maxBytes: one * 2 + one / 2)
        for (i, id) in ["a", "b", "c"].enumerated() {
            await cache.saveConversation(try snapshot(), key: key(id), savedAt: t0.addingTimeInterval(Double(i)))
        }
        #expect(await cache.conversation(key("a")) == nil)
        #expect(await cache.conversation(key("c")) != nil)
        #expect(await cache.bytes(hostId: host) <= one * 2 + one / 2)
    }

    @Test func réécritureRemplaceLEntrée() async throws {
        let storage = InMemoryOfflineCacheStorage()
        let cache = ConversationCache(storage: storage)
        await cache.saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        await cache.saveConversation(try snapshot(), key: key("s1"), savedAt: t0.addingTimeInterval(60))
        #expect(await cache.conversation(key("s1"))?.savedAt == t0.addingTimeInterval(60))
        #expect(storage.names.filter { $0 != "manifest.json" }.count == 1)
    }

    @Test func effacements() async throws {
        let cache = ConversationCache()
        let other = UUID()
        await cache.saveConversation(try snapshot(), key: key("a"), savedAt: t0)
        await cache.saveConversation(try snapshot(), key: key("b"), savedAt: t0)
        await cache.saveConversation(try snapshot(), key: key("x", host: other), savedAt: t0)
        await cache.saveSessions(try index(), hidden: [], hostId: host, workspace: "/w", savedAt: t0)
        await cache.remove(key("a"))
        #expect(await cache.conversation(key("a")) == nil)
        #expect(await cache.conversation(key("b")) != nil)
        await cache.removeAll(hostId: host)
        #expect(await cache.conversation(key("b")) == nil)
        #expect(await cache.sessions(hostId: host, workspace: "/w") == nil)
        #expect(await cache.bytes(hostId: host) == 0)
        #expect(await cache.conversation(key("x", host: other)) != nil)
    }

    @Test func manifesteIllisibleRepartDeZéro() async throws {
        let storage = InMemoryOfflineCacheStorage()
        await ConversationCache(storage: storage).saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        storage.corrupt("manifest.json")
        let cache = ConversationCache(storage: storage)
        #expect(await cache.conversation(key("s1")) == nil)
        #expect(storage.names.filter { $0 != "manifest.json" }.isEmpty)    // fichiers orphelins retirés
    }

    @Test func fichierIllisibleEffaceLEntrée() async throws {
        let storage = InMemoryOfflineCacheStorage()
        let cache = ConversationCache(storage: storage)
        await cache.saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        let file = try #require(storage.names.first { $0 != "manifest.json" })
        storage.corrupt(file)
        #expect(await cache.conversation(key("s1")) == nil)
        #expect(await cache.bytes(hostId: host) == 0)
        #expect(storage.names.filter { $0 != "manifest.json" }.isEmpty)
    }

    @Test func stockageFichier() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileOfflineCacheStorage(directory: dir)
        await ConversationCache(storage: storage).saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        #expect(await ConversationCache(storage: storage).conversation(key("s1"))?.savedAt == t0)
        storage.removeAll()
        #expect(storage.read("manifest.json") == nil)
    }

    /// Snapshot de 70 lignes (rowId 1…70) : une ligne réelle de `send-text-long` dupliquée.
    func longSnapshot() throws -> ConversationSnapshot {
        let wire = try Fixtures.record(in: "v3.15.1/send-text-long", prefix: "003")
        var snapshot = try #require(wire["frame"]?["payload"]?["snapshot"]?.objectValue)
        let template = try #require(snapshot["rows"]?["window"]?.arrayValue?.first?.objectValue)
        let window: [JSONValue] = (1...70).map { id in
            var row = template
            row["rowId"] = .number(Double(id))
            return .object(row)
        }
        snapshot["rows"] = .object(["window": .array(window), "totalCount": .number(70), "firstRowId": .number(1)])
        return try ConversationSnapshot(json: .object(snapshot))
    }

    @Test func troncatureÀLaFenêtreCourante() async throws {
        let cache = ConversationCache()
        let original = try longSnapshot()
        #expect(original.rows.count == 70)
        await cache.saveConversation(original, key: key("s1"), savedAt: t0)
        let copy = try #require(await cache.conversation(key("s1")))
        #expect(ConversationModel.historyPageSize == 60)
        #expect(copy.value.rows.map(\.rowId) == Array(11...70))
    }

    @Test func entréeSeuleTropGrosseÉvincée() async throws {
        let cache = ConversationCache(maxBytes: 10)
        await cache.saveConversation(try snapshot(), key: key("s1"), savedAt: t0)
        #expect(await cache.conversation(key("s1")) == nil)
        #expect(await cache.bytes(hostId: host) == 0)
    }
}
