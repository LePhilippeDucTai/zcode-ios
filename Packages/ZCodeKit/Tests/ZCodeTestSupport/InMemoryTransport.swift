import Foundation
import Synchronization
import ZCodeRPC
import ZCodeWire

/// Transport en mémoire : le test joue le rôle du serveur ZCode.
public final class InMemoryTransport: MessageTransport {
    public let messages: AsyncThrowingStream<Data, any Error>
    /// Messages envoyés par le client, dans l'ordre d'envoi.
    public let sent: AsyncStream<Data>
    private let toClient: AsyncThrowingStream<Data, any Error>.Continuation
    private let sentContinuation: AsyncStream<Data>.Continuation
    private let closed = Mutex(false)

    public init() {
        let (messages, toClient) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.messages = messages
        self.toClient = toClient
        let (sent, sentContinuation) = AsyncStream<Data>.makeStream()
        self.sent = sent
        self.sentContinuation = sentContinuation
    }

    public func send(_ message: Data) {
        sentContinuation.yield(message)
    }

    public func close() {
        closed.withLock { $0 = true }
        toClient.finish()
        sentContinuation.finish()
    }

    public var isClosed: Bool { closed.withLock { $0 } }

    /// Envoie au client une réponse « en-tête + corps ».
    public func deliver(_ header: RPCValue, _ body: RPCValue = .undefined) {
        toClient.yield(RPCSerializer.encode(header, body))
    }

    public func deliverInitialize() {
        deliver(.array([.int(ResponseType.initialize.rawValue)]))
    }

    public func deliverRaw(_ message: Data) {
        toClient.yield(message)
    }

    /// Simule une connexion qui échoue.
    public func fail(_ error: any Error) {
        toClient.finish(throwing: error)
    }

    /// Simule une connexion fermée normalement par le serveur.
    public func finish() {
        toClient.finish()
    }
}

/// Décode un message envoyé par le client.
public func decodeSent(_ data: Data) throws -> (header: RPCValue, body: RPCValue) {
    var reader = RPCReader(data)
    return (try reader.decode(), try reader.decode())
}

extension InMemoryTransport {
    /// Répond à l'appel `id` (réponse 201) avec une valeur JSON.
    public func respond(to id: Int32, with value: JSONValue) {
        deliver(.array([.int(201), .int(id)]), RPCValue(value))
    }

    /// Émet un événement pour l'écoute `id` (réponse 204), argument transmis tel quel.
    public func emit(listener id: Int32, _ value: JSONValue) {
        deliver(.array([.int(204), .int(id)]), .json(value))
    }
}
