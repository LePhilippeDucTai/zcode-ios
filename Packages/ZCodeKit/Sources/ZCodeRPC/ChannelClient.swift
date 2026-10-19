import Foundation
import ZCodeWire

/// Client des canaux RPC de ZCode (portage de `ChannelClient`, `packages/rpc/src/channelClient.ts`).
///
/// - Toute requête attend le message `Initialize` (200) du serveur.
/// - `call` envoie `[100, id, canal, méthode]` + argument ; annuler la tâche appelante envoie `[101, id]`.
/// - `listen` envoie `[102, id, canal, événement]` + argument ; terminer le flux envoie `[103, id]`.
/// - Quand la connexion se termine, les appels en attente échouent et les flux d'événements se terminent.
public actor ChannelClient {
    private enum State {
        case uninitialized
        case ready
        case closed(RPCError)
    }

    private let transport: any MessageTransport
    private var state = State.uninitialized
    private var nextRequestID: Int32 = 0
    private var initializationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingCalls: [Int32: CheckedContinuation<RPCValue, any Error>] = [:]
    private var listeners: [Int32: AsyncStream<RPCValue>.Continuation] = [:]
    private var readTask: Task<Void, Never>?

    public init(transport: any MessageTransport) {
        self.transport = transport
    }

    /// Un client abandonné sans `close()` ne doit pas laisser sa connexion ouverte.
    deinit {
        transport.close()
    }

    /// Démarre la lecture des messages du serveur. Sans effet si déjà démarrée.
    public func start() {
        guard readTask == nil else { return }
        let messages = transport.messages
        readTask = Task { [weak self] in
            do {
                for try await message in messages {
                    await self?.receive(message)
                }
                await self?.shutdown(.connectionClosed)
            } catch let error as TransportError {
                await self?.shutdown(.transport(error))
            } catch {
                await self?.shutdown(.transport(.connectionFailed(String(describing: error))))
            }
        }
    }

    /// Attend que le serveur ait envoyé `Initialize`.
    public func ready() async throws {
        switch state {
        case .ready:
            return
        case .closed(let error):
            throw error
        case .uninitialized:
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    initializationWaiters[waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelInitializationWaiter(waiterID) }
            }
        }
    }

    /// Appelle une méthode. Pour un service exposé par `ProxyChannel`, `arg` est le tableau des arguments.
    public func call(_ channel: String, _ method: String, _ arg: RPCValue = .undefined) async throws -> RPCValue {
        try await ready()
        try Task.checkCancellation()
        let id = allocateRequestID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RPCValue, any Error>) in
                if case .closed(let error) = state {
                    continuation.resume(throwing: error)
                    return
                }
                pendingCalls[id] = continuation
                transport.send(RPCMessage.request(.promise, id: id, channel: channel, name: method, arg: arg))
            }
        } onCancel: {
            Task { await self.cancelCall(id) }
        }
    }

    /// S'abonne à un événement. La requête d'écoute est envoyée avant le retour, ce qui garantit qu'un
    /// appel ultérieur (ex. `subscribe…`) atteint le serveur après elle.
    public func listen(_ channel: String, _ event: String, _ arg: RPCValue = .undefined) async throws -> AsyncStream<RPCValue> {
        try await ready()
        let id = allocateRequestID()
        let (stream, continuation) = AsyncStream<RPCValue>.makeStream()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopListening(id) }
        }
        transport.send(RPCMessage.request(.eventListen, id: id, channel: channel, name: event, arg: arg))
        return stream
    }

    public func close() {
        shutdown(.connectionClosed)
    }

    // MARK: - Interne

    private func allocateRequestID() -> Int32 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func receive(_ message: Data) {
        let response: RPCResponse
        do {
            response = try RPCMessage.parseResponse(message)
        } catch {
            shutdown(.protocolViolation("message illisible : \(error)"))
            return
        }
        switch response {
        case .initialize:
            guard case .uninitialized = state else { return }
            state = .ready
            let waiters = initializationWaiters.values
            initializationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        case .success(let id, let data):
            pendingCalls.removeValue(forKey: id)?.resume(returning: data)
        case .error(let id, let data):
            pendingCalls.removeValue(forKey: id)?.resume(throwing: RPCError.remote(RemoteError(data)))
        case .errorObject(let id, let data):
            pendingCalls.removeValue(forKey: id)?.resume(throwing: RPCError.errorObject(data))
        case .event(let id, let data):
            listeners[id]?.yield(data)
        case .unknown:
            break
        }
    }

    private func cancelInitializationWaiter(_ id: UUID) {
        initializationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelCall(_ id: Int32) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        transport.send(RPCMessage.dispose(.promiseCancel, id: id))
        continuation.resume(throwing: CancellationError())
    }

    private func stopListening(_ id: Int32) {
        guard listeners.removeValue(forKey: id) != nil else { return }
        if case .ready = state {
            transport.send(RPCMessage.dispose(.eventDispose, id: id))
        }
    }

    private func shutdown(_ error: RPCError) {
        if case .closed = state { return }
        state = .closed(error)
        // Fermer le transport avant de réveiller les appelants : ils observent une connexion déjà fermée.
        readTask?.cancel()
        transport.close()
        let waiters = initializationWaiters.values
        initializationWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        let calls = pendingCalls
        pendingCalls.removeAll()
        for call in calls.values { call.resume(throwing: error) }
        let streams = listeners
        listeners.removeAll()
        for stream in streams.values { stream.finish() }
    }
}
