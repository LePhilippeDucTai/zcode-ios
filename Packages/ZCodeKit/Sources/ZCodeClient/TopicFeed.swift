import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Appels propres à un sujet (abonnement, reprise, désinscription).
public struct TopicOperations: Sendable {
    public var subscribe: @Sendable (_ base: Watermark?) async throws -> SubscribeAck
    public var resync: @Sendable (_ subscriptionId: String, _ base: Watermark?, _ forceSnapshot: Bool) async throws -> SubscribeAck
    public var unsubscribe: @Sendable (_ subscriptionId: String) async throws -> Void

    public init(
        subscribe: @escaping @Sendable (_ base: Watermark?) async throws -> SubscribeAck,
        resync: @escaping @Sendable (_ subscriptionId: String, _ base: Watermark?, _ forceSnapshot: Bool) async throws -> SubscribeAck,
        unsubscribe: @escaping @Sendable (_ subscriptionId: String) async throws -> Void
    ) {
        self.subscribe = subscribe
        self.resync = resync
        self.unsubscribe = unsubscribe
    }
}

extension AgentV4 {
    public func conversationOperations(sessionId: String) -> TopicOperations {
        TopicOperations(
            subscribe: { base in try await self.subscribeConversation(sessionId: sessionId, base: base) },
            resync: { id, base, force in try await self.resyncConversation(subscriptionId: id, base: base, forceSnapshot: force) },
            unsubscribe: { id in try await self.unsubscribeConversation(subscriptionId: id) }
        )
    }

    public func sessionsIndexOperations() -> TopicOperations {
        TopicOperations(
            subscribe: { base in try await self.subscribeSessionsIndex(base: base) },
            resync: { id, base, force in try await self.resyncSessionsIndex(subscriptionId: id, base: base, forceSnapshot: force) },
            unsubscribe: { id in try await self.unsubscribeSessionsIndex(subscriptionId: id) }
        )
    }
}

/// Raisons d'échec de `TopicFeed` que l'app traite spécialement.
public enum TopicFeedFailure {
    /// Le flux de trames s'est terminé (connexion perdue) : se reconnecter puis se réabonner.
    public static let connectionLost = "connexion interrompue"
}

public enum FeedEvent<Projection: TopicProjection>: Sendable {
    case updated(Projection)
    /// Abonnement inutilisable (contenu illisible, connexion perdue, réabonnement impossible).
    case failed(String)
}

/// Fait vivre un `TopicStore` : trames → réassemblage → store, et exécution des effets.
public actor TopicFeed<Projection: TopicProjection> {
    public nonisolated let topic: String
    /// Mises à jour pour l'interface (un seul consommateur).
    public nonisolated let events: AsyncStream<FeedEvent<Projection>>
    private let continuation: AsyncStream<FeedEvent<Projection>>.Continuation
    private let operations: TopicOperations
    private let recoveryTimeout: Duration
    private var store: TopicStore<Projection>
    private var assembler: WireAssembler
    private var framesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var stopped = false
    /// Dernière erreur bloquante.
    public private(set) var failure: String?

    public init(
        topic: String,
        operations: TopicOperations,
        limits: WireLimits = .protocolDefaults,
        recoveryTimeout: Duration = .seconds(30)
    ) {
        self.topic = topic
        let (events, continuation) = AsyncStream<FeedEvent<Projection>>.makeStream()
        self.events = events
        self.continuation = continuation
        self.operations = operations
        self.recoveryTimeout = recoveryTimeout
        store = TopicStore(topic: topic)
        assembler = WireAssembler(limits: limits)
    }

    public var current: Projection? { store.projection }
    public var watermark: Watermark? { store.watermark }

    /// Lit `frames` (écoute déjà ouverte, pour ne manquer aucune trame) puis s'abonne.
    public func start(frames: AsyncStream<JSONValue>, base: Watermark? = nil) async throws {
        framesTask = Task { [weak self] in
            for await wire in frames {
                await self?.ingest(wire)
            }
            // Une tâche annulée (échec d'abonnement, arrêt) n'est pas une perte de connexion.
            guard !Task.isCancelled else { return }
            await self?.framesEnded()
        }
        let ack: SubscribeAck
        do {
            ack = try await operations.subscribe(base)
        } catch {
            // Sans abonnement, l'écoute (trafic de tout l'espace de travail) ne doit pas rester ouverte.
            framesTask?.cancel()
            framesTask = nil
            throw error
        }
        if stopped {
            // Arrêté avant l'accusé : `stop()` ne connaissait pas encore l'abonnement.
            try? await operations.unsubscribe(ack.subscriptionId)
            return
        }
        run(store.subscribed(ack))
        armWatchdogIfWaiting()
        publish()
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        framesTask?.cancel()
        expiryTask?.cancel()
        recoveryTask?.cancel()
        if let subscriptionId = store.subscriptionId {
            try? await operations.unsubscribe(subscriptionId)
        }
        continuation.finish()
    }

    // MARK: - Trames

    private func ingest(_ wire: JSONValue) {
        // Le flux couvre tout l'espace de travail : seules les trames de ce sujet sont réassemblées.
        guard !stopped, wire["topic"]?.stringValue == topic else { return }
        for event in assembler.accept(wire, now: .now) {
            handle(event)
        }
        scheduleExpiry()
    }

    private func handle(_ event: AssemblyEvent) {
        switch event {
        case .complete(let frame):
            let previousSeq = store.seq
            let previousWatermark = store.watermark
            run(store.receive(frame))
            if !store.isRecovering, !store.isAwaitingInitial { recoveryTask?.cancel() }
            if store.seq != previousSeq || store.watermark != previousWatermark { publish() }
        case .fault(let fault):
            run(store.assemblyFault(fault))
        }
    }

    private func framesEnded() {
        guard !stopped else { return }
        fail(TopicFeedFailure.connectionLost)
    }

    // MARK: - Effets

    private func run(_ effects: [TopicEffect]) {
        for effect in effects {
            switch effect {
            case .resync(let subscriptionId, let base, let forceSnapshot):
                scheduleRecoveryTimeout()
                let operations = operations
                Task {
                    do {
                        let ack = try await operations.resync(subscriptionId, base, forceSnapshot)
                        self.resyncAcknowledged(ack)
                    } catch {
                        self.resyncFailed()
                    }
                }
            case .resubscribe:
                // Oublier l'ancienne génération avant d'appeler le serveur : la trame initiale du nouvel
                // abonnement peut arriver avant son accusé et doit être mise en attente, pas jetée.
                if let previous = store.subscriptionId {
                    assembler.discard(WireRoute(topic: topic, subscriptionId: previous))
                }
                store.resubscribing()
                let operations = operations
                Task {
                    do {
                        let ack = try await operations.subscribe(nil)
                        self.resubscribed(ack)
                    } catch {
                        self.fail("réabonnement impossible (\(error))")
                    }
                }
            case .contentRejected(let reason):
                fail(reason)
            }
        }
    }

    private func resyncAcknowledged(_ ack: SubscribeAck) {
        guard !stopped else { return }
        run(store.resyncAcknowledged(ack))
        if !store.isRecovering { recoveryTask?.cancel() }
        armWatchdogIfWaiting()
    }

    private func resyncFailed() {
        guard !stopped else { return }
        recoveryTask?.cancel()
        run(store.resyncFailed())
    }

    private func resubscribed(_ ack: SubscribeAck) {
        guard !stopped else { return }
        run(store.subscribed(ack))
        armWatchdogIfWaiting()
        publish()
    }

    private func scheduleRecoveryTimeout() {
        recoveryTask?.cancel()
        let timeout = recoveryTimeout
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.recoveryTimedOut()
        }
    }

    /// Borne aussi l'attente du snapshot initial : sans lui, les deltas sont ignorés indéfiniment.
    private func armWatchdogIfWaiting() {
        if store.isAwaitingInitial, !store.isRecovering { scheduleRecoveryTimeout() }
    }

    private func recoveryTimedOut() {
        guard !stopped else { return }
        if store.isRecovering {
            run(store.recoveryTimedOut())
        } else if store.isAwaitingInitial {
            run(store.initialTimedOut())
        }
    }

    /// Fait expirer un assemblage incomplet même si plus aucune trame n'arrive.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = assembler.nextDeadline else {
            expiryTask = nil
            return
        }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.expireAssemblies()
        }
    }

    private func expireAssemblies() {
        guard !stopped else { return }
        for event in assembler.expire(now: .now) {
            handle(event)
        }
        scheduleExpiry()
    }

    private func publish() {
        if let projection = store.projection {
            continuation.yield(.updated(projection))
        }
    }

    private func fail(_ reason: String) {
        failure = reason
        continuation.yield(.failed(reason))
    }
}

extension TopicFeed where Projection == ConversationSnapshot {
    /// Ajoute une page d'historique ; `false` si elle date d'une autre époque du journal.
    public func mergeOlderRows(_ page: RowsRangePage) -> Bool {
        let merged = store.mergeOlderRows(page)
        if merged { publish() }
        return merged
    }
}
