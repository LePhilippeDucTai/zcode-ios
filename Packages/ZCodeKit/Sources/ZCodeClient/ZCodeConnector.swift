import Foundation
import ZCodeRPC

public enum ConnectorError: Error, Equatable, Sendable {
    /// Le serveur n'a pas envoyé `Initialize` à temps.
    case timeout
}

/// Ouvre une connexion RPC vers un serveur ZCode et attend qu'elle soit prête.
public enum ZCodeConnector {
    public static func connect(
        to endpoint: HostEndpoint,
        session: URLSession = .zcode,
        timeout: Duration = .seconds(10)
    ) async throws -> ChannelClient {
        try await connect(transport: WebSocketTransport(url: endpoint.webSocketURL, session: session), timeout: timeout)
    }

    public static func connect(transport: any MessageTransport, timeout: Duration) async throws -> ChannelClient {
        let client = ChannelClient(transport: transport)
        await client.start()
        // Chien de garde : à l'expiration, fermer le client débloque `ready()`.
        let watchdog = Task { () -> Bool in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            await client.close()
            return true
        }
        do {
            try await client.ready()
            watchdog.cancel()
            return client
        } catch {
            watchdog.cancel()
            await client.close()
            if await watchdog.value {
                throw ConnectorError.timeout
            }
            throw error
        }
    }
}
