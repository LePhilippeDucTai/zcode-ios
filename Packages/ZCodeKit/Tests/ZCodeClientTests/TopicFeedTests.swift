import Foundation
import Synchronization
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct TopicFeedTests {
    static let session = "sess_45199523-12a0-4928-92e6-ff082723da62"
    static let sub2 = "sub-mv6j6gf9-m0d4m1jc-2"
    static let epoch = "mv6j6gf9-m0d4m1jc"

    /// send-text : [2] accusé, [3] snapshot initial (seq 13), [5…8] deltas 006…009.
    let records: [FixtureRecord]

    init() throws {
        records = try Fixtures.records(in: "v3.15.1/send-text")
    }

    func retagged(_ index: Int, ordinal: Int, delivery: String = "online") throws -> JSONValue {
        var wire = try #require(records[index].value.objectValue)
        wire["logicalFrameOrdinal"] = .number(Double(ordinal))
        wire["deliveryKind"] = .string(delivery)
        return .object(wire)
    }

    func makeFeed(_ agent: AgentV4, limits: WireLimits = .protocolDefaults) -> TopicFeed<ConversationSnapshot> {
        TopicFeed(topic: Topic.conversation(Self.session), operations: agent.conversationOperations(sessionId: Self.session), limits: limits)
    }

    @Test func conversationReelleTrameInitialeAvantAccuse() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()                                             // écoute (id 0)
        async let started: Void = feed.start(frames: frames)
        let subscribe = try decodeSent(#require(await sent.next()))       // abonnement (id 1)
        #expect(subscribe.header == agentCall(1, "subscribeConversationV4"))
        transport.emit(listener: 0, records[3].value)                     // la trame initiale précède l'accusé
        transport.respond(to: 1, with: records[2].value)
        for record in records[5...] { transport.emit(listener: 0, record.value) }
        try await started
        let final = try await eventually { await feed.current.flatMap { $0.revision == 24 ? $0 : nil } }
        #expect(final.control?.phase == .completedSuccess)
        #expect(await feed.watermark == Watermark(logEpoch: Self.epoch, seq: 184))
        #expect(await feed.failure == nil)
    }

    @Test func trouPuisReprise() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()
        async let started: Void = feed.start(frames: frames)
        _ = await sent.next()
        transport.respond(to: 1, with: records[2].value)
        transport.emit(listener: 0, records[3].value)
        try await started
        transport.emit(listener: 0, records[5].value)                     // 006 : seq 13 → 17
        transport.emit(listener: 0, records[7].value)                     // 008 : trou (57 attendu à partir de 17)
        let resync = try decodeSent(#require(await sent.next()))
        #expect(resync.header == agentCall(2, "resyncConversationV4"))
        #expect(resync.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "subscriptionId": .string(Self.sub2),
            "base": .object(["logEpoch": .string(Self.epoch), "seq": .number(17)]), "forceSnapshot": .bool(false),
        ]))]))
        transport.respond(to: 2, with: .object(["ack": .object([
            "subscriptionId": .string(Self.sub2), "mode": .string("resume"), "logEpoch": .string(Self.epoch),
        ])]))
        transport.emit(listener: 0, try retagged(6, ordinal: 10, delivery: "recovery"))   // 007 renvoyée en reprise
        transport.emit(listener: 0, try retagged(7, ordinal: 11))                          // 008 puis 009 en direct
        transport.emit(listener: 0, try retagged(8, ordinal: 12))
        let final = try await eventually { await feed.current.flatMap { $0.revision == 24 ? $0 : nil } }
        #expect(final.control?.phase == .completedSuccess)
    }

    @Test func fragmentOrphelinDeclencheUneResync() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        var limits = WireLimits.protocolDefaults
        limits.timeout = .milliseconds(100)
        let feed = makeFeed(agent, limits: limits)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()
        async let started: Void = feed.start(frames: frames)
        _ = await sent.next()
        transport.respond(to: 1, with: records[2].value)
        transport.emit(listener: 0, records[3].value)
        try await started
        // Premier fragment d'une trame dont la suite n'arrive jamais (Mac mis en veille).
        transport.emit(listener: 0, .object([
            "wireVersion": .number(3), "kind": .string("fragment"), "deliveryKind": .string("online"),
            "logicalFrameId": .string("lf-orphelin"), "logicalFrameOrdinal": .number(2),
            "topic": .string(Topic.conversation(Self.session)), "subscriptionId": .string(Self.sub2),
            "fragmentIndex": .number(0), "fragmentCount": .number(2), "logicalBytes": .number(10),
            "checksum": .object(["algorithm": .string("crc32"), "value": .string("00000000")]),
            "dataBase64": .string("QUJD"),
        ]))
        let resync = try decodeSent(#require(await sent.next()))         // envoyée à l'expiration, sans autre trame
        #expect(resync.header == agentCall(2, "resyncConversationV4"))
        #expect(resync.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "subscriptionId": .string(Self.sub2),
            "base": .object(["logEpoch": .string(Self.epoch), "seq": .number(13)]), "forceSnapshot": .bool(false),
        ]))]))
    }

    @Test func contenuIllisibleSignale() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()
        async let started: Void = feed.start(frames: frames)
        _ = await sent.next()
        transport.respond(to: 1, with: records[2].value)
        var wire = try #require(records[3].value.objectValue)
        var envelope = try #require(wire["frame"]?.objectValue)
        envelope["payload"] = .object(["kind": .string("snapshot"), "snapshot": .object(["sessionId": .string("x")])])
        wire["frame"] = .object(envelope)
        transport.emit(listener: 0, .object(wire))
        try await started
        let failure = try await eventually { await feed.failure }
        #expect(failure.contains("snapshot illisible"))
        #expect(await feed.current == nil)
    }

    @Test func arretSeDesabonne() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()
        async let started: Void = feed.start(frames: frames)
        _ = await sent.next()
        transport.respond(to: 1, with: records[2].value)
        transport.emit(listener: 0, records[3].value)
        try await started
        async let stopping: Void = feed.stop()
        // La fin d'écoute (103) et la désinscription (100) partent dans un ordre non garanti.
        var unsubscribe: (header: RPCValue, body: RPCValue)?
        for _ in 0..<2 {
            let message = try decodeSent(#require(await sent.next()))
            if message.header == agentCall(2, "unsubscribeConversationV4") { unsubscribe = message }
        }
        let request = try #require(unsubscribe)
        #expect(request.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "subscriptionId": .string(Self.sub2),
        ]))]))
        transport.respond(to: 2, with: .null)
        await stopping
    }

    @Test func reabonnementApresEchecDeResyncTrameInitialeAvantAccuse() async throws {
        let long = try Fixtures.records(in: "v3.15.1/send-text-long")
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        _ = await sent.next()
        async let started: Void = feed.start(frames: frames)
        _ = await sent.next()
        transport.respond(to: 1, with: records[2].value)
        transport.emit(listener: 0, records[3].value)
        try await started
        transport.emit(listener: 0, records[5].value)                     // 006
        transport.emit(listener: 0, records[7].value)                     // 008 : trou → resync (id 2)
        let resync = try decodeSent(#require(await sent.next()))
        #expect(resync.header == agentCall(2, "resyncConversationV4"))
        transport.deliver(.array([.int(202), .int(2)]), .json(.object(["message": .string("CLI redémarrée"), "name": .string("Error")])))
        let resubscribe = try decodeSent(#require(await sent.next()))   // échec → réabonnement (id 3)
        #expect(resubscribe.header == agentCall(3, "subscribeConversationV4"))
        // La trame initiale du nouvel abonnement précède son accusé.
        transport.emit(listener: 0, long[2].value)
        try await Task.sleep(for: .milliseconds(100))
        transport.respond(to: 3, with: long[3].value)
        let final = try await eventually(timeout: .seconds(3)) { await feed.current.flatMap { $0.revision == 24 ? $0 : nil } }
        #expect(final.rows.count == 10)
        #expect(await feed.watermark == Watermark(logEpoch: Self.epoch, seq: 184))
    }

    @Test func arretPendantLAbonnementSeDesabonne() async throws {
        let (agent, transport) = await connectedAgent()
        let headers = SentHeaders(transport)
        let feed = makeFeed(agent)
        let frames = try await agent.conversationFrames()
        async let started: Void = feed.start(frames: frames)
        _ = try await eventually { headers.all.contains(agentCall(1, "subscribeConversationV4")) ? true : nil }
        await feed.stop()                                                        // remplacé avant l'accusé
        transport.respond(to: 1, with: records[2].value)
        _ = try await eventually { headers.all.contains(agentCall(2, "unsubscribeConversationV4")) ? true : nil }
        transport.respond(to: 2, with: .null)
        try? await started
    }

    @Test func abonnementRefuseFermeLEcoute() async throws {
        let server = FakeZCodeServer()                        // subscribeConversationV4 non simulé : erreur 202
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        let agent = AgentV4(client: client, workspacePath: testWorkspace)
        let feed = makeFeed(agent)
        let failures = Mutex<[String]>([])
        let events = feed.events
        let collector = Task {
            for await event in events {
                if case .failed(let reason) = event { failures.withLock { $0.append(reason) } }
            }
        }
        defer { collector.cancel() }
        await #expect(throws: (any Error).self) { try await feed.start(frames: agent.conversationFrames()) }
        _ = try await eventually {
            await server.listenerCount("zcode-agent.onDynamicConversationFrame") == 0 ? true : nil
        }
        // L'annulation volontaire n'est pas une perte de connexion : l'appelant reçoit déjà l'erreur d'abonnement.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await feed.failure == nil)
        #expect(failures.withLock { $0 }.isEmpty)
    }
}

/// En-têtes des messages envoyés par le client, relevés en continu.
final class SentHeaders: Sendable {
    private let headers = Mutex<[RPCValue]>([])

    init(_ transport: InMemoryTransport) {
        let sent = transport.sent
        Task { [weak self] in
            for await message in sent {
                if let header = try? decodeSent(message).header { self?.append(header) }
            }
        }
    }

    private func append(_ header: RPCValue) { headers.withLock { $0.append(header) } }

    var all: [RPCValue] { headers.withLock { $0 } }
}
