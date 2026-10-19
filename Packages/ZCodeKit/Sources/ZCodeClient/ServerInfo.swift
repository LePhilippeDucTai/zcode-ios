import Foundation
import ZCodeWire

/// Réponse de `GET /api/server-info` (`ServerRemoteInfo`, `packages/shared/src/server-remote.ts`).
public struct ServerInfo: Codable, Equatable, Sendable {
    public struct Workspace: Codable, Equatable, Sendable {
        public let path: String
        public let label: String?
        public let workspaceIdentity: String?

        public init(path: String, label: String?, workspaceIdentity: String?) {
            self.path = path
            self.label = label
            self.workspaceIdentity = workspaceIdentity
        }
    }

    public let serverId: String
    public let name: String?
    public let version: String
    public let protocolVersion: Int
    public let authRequired: Bool
    public let workspaces: [Workspace]
    public let capabilities: JSONValue
}

public enum ServerInfoError: Error, Equatable, Sendable {
    /// Token absent ou refusé (HTTP 401).
    case unauthorized
    case httpStatus(Int)
    case invalidResponse
    /// Échec réseau ; le message ne reprend jamais l'URL (qui contient le token).
    case network(String)
}

extension ServerInfo {
    public static func fetch(from endpoint: HostEndpoint, session: URLSession = .zcode) async throws -> ServerInfo {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: endpoint.serverInfoURL)
        } catch {
            // Une annulation reste une annulation (pas une « erreur réseau » à afficher).
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // `URLError` porte l'URL complète (donc le token) dans son `userInfo` : ne garder que le message.
            throw ServerInfoError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServerInfoError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(ServerInfo.self, from: data)
            } catch {
                throw ServerInfoError.invalidResponse
            }
        case 401:
            throw ServerInfoError.unauthorized
        default:
            throw ServerInfoError.httpStatus(http.statusCode)
        }
    }
}
