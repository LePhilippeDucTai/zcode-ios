import Foundation
import ZCodeRPC
import ZCodeWire

/// Transport RPC sur `URLSessionWebSocketTask` : encadre les messages sortants et réassemble les
/// trames entrantes (le serveur `/ws` utilise `SocketProtocol`, sans accusés de réception).
public final class WebSocketTransport: MessageTransport {
    public let messages: AsyncThrowingStream<Data, any Error>
    private let task: URLSessionWebSocketTask
    private let outgoing: AsyncStream<Data>.Continuation

    /// - Parameter maximumMessageSize: le défaut d'`URLSessionWebSocketTask` (1 Mio) est trop petit :
    ///   certaines réponses RPC ne sont pas fragmentées (ex. `file.readBinaryPreview`, jusqu'à 25 Mio
    ///   avant encodage base64). Vérifié en réel : réponse de 4 Mio reçue intacte (`Probe/large-file.json`).
    /// - Parameter keepAliveInterval: intervalle des pings WebSocket (`nil` : aucun) ; sans pong sous
    ///   `keepAliveTimeout`, la connexion échoue avec `TransportError.connectionFailed`.
    public init(
        url: URL,
        session: URLSession = .zcode,
        maximumMessageSize: Int = 64 << 20,
        keepAliveInterval: Duration? = .seconds(20),
        keepAliveTimeout: Duration = .seconds(10)
    ) {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        self.task = task
        let (messages, incoming) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.messages = messages
        let (outgoingStream, outgoing) = AsyncStream<Data>.makeStream()
        self.outgoing = outgoing

        let keepAlive: Task<Void, Never>? = keepAliveInterval.map { interval in
            Task {
                let failure = await KeepAlive.run(every: interval, timeout: keepAliveTimeout) {
                    try await Self.ping(task)
                }
                if let failure {
                    incoming.finish(throwing: failure)
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
        }
        incoming.onTermination = { _ in
            keepAlive?.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }
        task.resume()

        // Émetteur unique : préserve l'ordre des messages.
        Task {
            for await message in outgoingStream {
                do {
                    try await task.send(.data(FrameCodec.encodeRegular(message)))
                } catch {
                    incoming.finish(throwing: Self.transportError(for: error, task: task))
                    return
                }
            }
        }

        // Récepteur : réassemble les trames et publie les charges utiles `regular`.
        Task {
            var decoder = FrameDecoder(maximumPayloadSize: maximumMessageSize)
            do {
                while true {
                    switch try await task.receive() {
                    case .data(let chunk):
                        for payload in try decoder.append(chunk) {
                            incoming.yield(payload)
                        }
                    case .string:
                        throw TransportError.unexpectedTextMessage
                    @unknown default:
                        throw TransportError.unexpectedTextMessage
                    }
                }
            } catch {
                incoming.finish(throwing: Self.transportError(for: error, task: task))
            }
        }
    }

    public func send(_ message: Data) {
        outgoing.yield(message)
    }

    public func close() {
        outgoing.finish()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private static func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func transportError(for error: any Error, task: URLSessionWebSocketTask) -> TransportError {
        if let transportError = error as? TransportError {
            return transportError
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            return .unauthorized
        }
        return .connectionFailed(error.localizedDescription)
    }
}
