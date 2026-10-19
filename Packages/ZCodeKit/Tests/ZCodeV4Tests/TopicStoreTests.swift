import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Passe un enregistrement réel dans un réassembleur neuf ; `delivery`/`subscriptionId`/`ordinal` permettent
/// de simuler une trame de reprise ou un autre abonnement.
func logical(_ wire: JSONValue, delivery: DeliveryKind? = nil, subscriptionId: String? = nil, ordinal: Int? = nil) throws -> LogicalFrame {
    var object = try #require(wire.objectValue)
    if let delivery { object["deliveryKind"] = .string(delivery.rawValue) }
    if let ordinal { object["logicalFrameOrdinal"] = .number(Double(ordinal)) }
    if let subscriptionId {
        object["subscriptionId"] = .string(subscriptionId)
        var frame = try #require(object["frame"]?.objectValue)
        frame["subscriptionId"] = .string(subscriptionId)
        object["frame"] = .object(frame)
    }
    var assembler = WireAssembler()
    return try #require(completes(assembler.accept(.object(object), now: .now)).first)
}

struct TopicStoreTests {
    static let session = "sess_45199523-12a0-4928-92e6-ff082723da62"
    static let sub2 = "sub-mv6j6gf9-m0d4m1jc-2"
    static let epoch = "mv6j6gf9-m0d4m1jc"

    let short: [FixtureRecord]   // send-text : accusé (003) puis snapshot (004), deltas 006…009
    let long: [FixtureRecord]    // send-text-long : snapshot (003) puis accusé (004), deltas 006…013

    init() throws {
        short = try Fixtures.records(in: "v3.15.1/send-text")
        long = try Fixtures.records(in: "v3.15.1/send-text-long")
    }

    func frame(_ records: [FixtureRecord], _ prefix: String, delivery: DeliveryKind? = nil) throws -> LogicalFrame {
        try logical(#require(records.first { $0.file.hasPrefix(prefix) }).value, delivery: delivery)
    }

    func ack(_ records: [FixtureRecord], _ prefix: String) throws -> SubscribeAck {
        try SubscribeAck(result: #require(records.first { $0.file.hasPrefix(prefix) }).value)
    }

    /// Store abonné (send-text) avec le snapshot initial appliqué : seq 13, révision 9.
    func subscribedStore() throws -> ConversationStore {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        #expect(store.subscribed(try ack(short, "003")).isEmpty)
        #expect(store.receive(try frame(short, "004")).isEmpty)
        return store
    }

    @Test func accuseAvantTrameInitiale() throws {
        var store = try subscribedStore()
        #expect(store.projection?.revision == 9)
        #expect(store.seq == 13)
        #expect(store.watermark == Watermark(logEpoch: Self.epoch, seq: 13))
        for prefix in ["006", "007", "008", "009"] {
            #expect(store.receive(try frame(short, prefix)).isEmpty)
        }
        #expect(store.seq == 184)
        #expect(store.projection?.revision == 24)
        #expect(store.projection?.control?.phase == .completedSuccess)
    }

    @Test func trameInitialeAvantAccuse() throws {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        #expect(store.receive(try frame(long, "003")).isEmpty)
        #expect(store.projection == nil)                           // mise en attente
        #expect(store.subscribed(try ack(long, "004")).isEmpty)
        #expect(store.seq == 184)
        #expect(store.projection?.revision == 24)
        for prefix in ["006", "007", "008", "009", "010", "011", "012", "013"] {
            #expect(store.receive(try frame(long, prefix)).isEmpty)
        }
        #expect(store.seq == 945)
        #expect(store.projection?.revision == 31)
    }

    @Test func trameDUnAncienAbonnementIgnoree() throws {
        var store = try subscribedStore()
        // Trame d'une autre génération (sub-…-3, fromSeq 184) : ignorée, pas de resync.
        #expect(store.receive(try frame(long, "006")).isEmpty)
        #expect(store.seq == 13)
        // Réabonnement après reconnexion : l'ancienne génération est désormais ignorée à son tour.
        #expect(store.subscribed(try ack(long, "004")).isEmpty)
        #expect(store.watermark == nil)                            // accusé « snapshot » : base invalidée
        #expect(store.receive(try frame(short, "006")).isEmpty)
        #expect(store.receive(try frame(long, "003")).isEmpty)
        #expect(store.projection?.revision == 24)
        #expect(store.seq == 184)
    }

    @Test func doublonIgnore() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "007"))
        let before = store.projection
        #expect(store.receive(try frame(short, "006")).isEmpty)
        #expect(store.seq == 57)
        #expect(store.projection == before)
    }

    @Test func trouDeclencheUneSeuleResync() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        #expect(store.receive(try frame(short, "008")) == [
            .resync(subscriptionId: Self.sub2, base: Watermark(logEpoch: Self.epoch, seq: 17), forceSnapshot: false),
        ])
        #expect(store.isRecovering)
        #expect(store.receive(try frame(short, "009")).isEmpty)    // déjà en reprise : pas de deuxième demande
        #expect(store.seq == 17)
    }

    @Test func repriseRecuperee() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        #expect(store.resyncAcknowledged(SubscribeAck(subscriptionId: Self.sub2, mode: .resume, logEpoch: Self.epoch)).isEmpty)
        #expect(store.receive(try frame(short, "007", delivery: .recovery)).isEmpty)
        #expect(!store.isRecovering)
        #expect(store.receive(try frame(short, "008")).isEmpty)
        #expect(store.receive(try frame(short, "009")).isEmpty)
        #expect(store.seq == 184)
        #expect(store.projection?.control?.phase == .completedSuccess)
    }

    @Test func repriseQuiPresenteUnTrouForceUnSnapshot() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        _ = store.resyncAcknowledged(SubscribeAck(subscriptionId: Self.sub2, mode: .resume, logEpoch: Self.epoch))
        #expect(store.receive(try frame(short, "008", delivery: .recovery)) == [
            .resync(subscriptionId: Self.sub2, base: Watermark(logEpoch: Self.epoch, seq: 17), forceSnapshot: true),
        ])
        #expect(store.receive(try frame(short, "009", delivery: .recovery)).isEmpty)   // déjà forcé : pas de boucle
    }

    @Test func accuseSnapshotPuisTrameDeReprise() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        #expect(store.resyncAcknowledged(SubscribeAck(subscriptionId: Self.sub2, mode: .snapshot, logEpoch: Self.epoch)).isEmpty)
        #expect(store.watermark == nil)
        #expect(store.receive(try frame(short, "007")).isEmpty)    // delta sans base en attendant le snapshot : ignoré
        let recovery = try logical(#require(long.first { $0.file.hasPrefix("003") }).value,
                                   delivery: .recovery, subscriptionId: Self.sub2, ordinal: 10)
        #expect(store.receive(recovery).isEmpty)
        #expect(!store.isRecovering)
        #expect(store.seq == 184)
        #expect(store.projection?.revision == 24)
    }

    @Test func trameDeRepriseAvantAccuse() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        let recovery = try logical(#require(long.first { $0.file.hasPrefix("003") }).value,
                                   delivery: .recovery, subscriptionId: Self.sub2, ordinal: 10)
        #expect(store.receive(recovery).isEmpty)
        #expect(store.isRecovering)                                // l'accusé n'est pas encore arrivé
        #expect(store.resyncAcknowledged(SubscribeAck(subscriptionId: Self.sub2, mode: .snapshot, logEpoch: Self.epoch)).isEmpty)
        #expect(!store.isRecovering)
        #expect(store.watermark == Watermark(logEpoch: Self.epoch, seq: 184))   // la base reçue reste valable
    }

    @Test func fauteDAssemblageDemandeUneResync() throws {
        var store = try subscribedStore()
        let route = WireRoute(topic: Topic.conversation(Self.session), subscriptionId: Self.sub2)
        #expect(store.assemblyFault(WireFault(reasonCode: WireFault.Reason.timedOut, route: route, ordinal: 5, deliveryKind: .online)) == [
            .resync(subscriptionId: Self.sub2, base: Watermark(logEpoch: Self.epoch, seq: 13), forceSnapshot: false),
        ])
        var fresh = ConversationStore(topic: Topic.conversation(Self.session))
        _ = fresh.subscribed(try ack(short, "003"))
        #expect(fresh.assemblyFault(WireFault(reasonCode: WireFault.Reason.checksumMismatch, route: route, ordinal: 1, deliveryKind: .initial)) == [
            .resync(subscriptionId: Self.sub2, base: nil, forceSnapshot: true),
        ])
        var other = try subscribedStore()
        let unsupported = other.assemblyFault(WireFault(reasonCode: WireFault.Reason.wireVersionUnsupported, route: route, ordinal: 6, deliveryKind: .online))
        guard case .contentRejected = try #require(unsupported.first) else { Issue.record("rejet attendu"); return }
    }

    @Test func snapshotIllisibleSansBoucle() throws {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        _ = store.subscribed(try ack(short, "003"))
        var wire = try #require(short.first { $0.file.hasPrefix("004") }?.value.objectValue)
        var envelope = try #require(wire["frame"]?.objectValue)
        envelope["payload"] = .object(["kind": .string("snapshot"), "snapshot": .object(["sessionId": .string("x")])])
        wire["frame"] = .object(envelope)
        let effects = store.receive(try logical(.object(wire)))
        guard case .contentRejected = try #require(effects.first) else { Issue.record("rejet attendu"); return }
        #expect(effects.count == 1)
        #expect(store.projection == nil)
    }

    @Test func debordementAvantAccuse() throws {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        let early = try frame(short, "006")
        for _ in 0...ConversationStore.maxStagedFrames {
            #expect(store.receive(early).isEmpty)
        }
        #expect(store.subscribed(try ack(short, "003")) == [.resync(subscriptionId: Self.sub2, base: nil, forceSnapshot: true)])
    }

    @Test func delaiDeRepriseEscalade() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        #expect(store.recoveryTimedOut() == [.resync(subscriptionId: Self.sub2, base: Watermark(logEpoch: Self.epoch, seq: 17), forceSnapshot: true)])
        #expect(store.recoveryTimedOut() == [.resubscribe])
        #expect(!store.isRecovering)
        #expect(store.resyncFailed().isEmpty)
    }

    @Test func echecDeResyncDemandeUnReabonnement() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))
        #expect(store.resyncFailed() == [.resubscribe])
        #expect(!store.isRecovering)
    }

    @Test func indexDesSessions() throws {
        let records = try Fixtures.records(in: "v3.15.1/handshake-sessions")
        var store = SessionsIndexStore(topic: Topic.sessionsIndex("/Users/me/claude"))
        #expect(store.topic == "sessions-index//Users/me/claude")
        _ = store.subscribed(try SubscribeAck(result: #require(records.first { $0.file.hasPrefix("003") }).value))
        _ = store.receive(try logical(#require(records.first { $0.file.hasPrefix("004") }).value))
        #expect(store.projection?.sessions.count == 1)
        #expect(store.seq == 1)
    }

    @Test func reabonnementMetEnAttenteLaTrameInitialeDuNouvelAbonnement() throws {
        var store = try subscribedStore()
        store.resubscribing()
        #expect(store.subscriptionId == nil)
        // La trame initiale du nouvel abonnement arrive avant son accusé : elle doit être gardée, pas jetée.
        #expect(store.receive(try frame(long, "003")).isEmpty)
        #expect(store.projection?.revision == 9)
        #expect(store.subscribed(try ack(long, "004")).isEmpty)
        #expect(store.projection?.revision == 24)
        #expect(store.seq == 184)
    }

    @Test func attenteDuSnapshotInitialBornee() throws {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        _ = store.subscribed(try ack(short, "003"))
        #expect(store.isAwaitingInitial)
        #expect(store.initialTimedOut() == [.resync(subscriptionId: Self.sub2, base: nil, forceSnapshot: true)])
        var ready = try subscribedStore()
        #expect(!ready.isAwaitingInitial)
        #expect(ready.initialTimedOut().isEmpty)
    }

    @Test func repriseSansEtatLocalDemandeUnSnapshot() {
        var store = ConversationStore(topic: Topic.conversation(Self.session))
        // Accusé « resume » alors que ce store ne détient aucun état : rien ne viendra combler l'attente.
        #expect(store.subscribed(SubscribeAck(subscriptionId: Self.sub2, mode: .resume, logEpoch: Self.epoch)) == [
            .resync(subscriptionId: Self.sub2, base: nil, forceSnapshot: true),
        ])
    }

    @Test func trouApresLaTrameDeRepriseRelanceUneResync() throws {
        var store = try subscribedStore()
        _ = store.receive(try frame(short, "006"))
        _ = store.receive(try frame(short, "008"))                       // trou → resync (base 17)
        #expect(store.receive(try frame(short, "007", delivery: .recovery)).isEmpty)   // seq 57, accusé pas encore reçu
        #expect(store.receive(try frame(short, "009")).isEmpty)          // nouveau trou (63 ≠ 57) pendant l'attente de l'accusé
        #expect(store.resyncAcknowledged(SubscribeAck(subscriptionId: Self.sub2, mode: .resume, logEpoch: Self.epoch)) == [
            .resync(subscriptionId: Self.sub2, base: Watermark(logEpoch: Self.epoch, seq: 57), forceSnapshot: false),
        ])
    }
}
