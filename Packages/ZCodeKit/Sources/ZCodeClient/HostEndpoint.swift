import Foundation

/// Adresse d'un serveur `zcode --web` et son token d'accès.
///
/// Le token donne un accès shell à l'hôte : ne jamais journaliser ces URL.
public struct HostEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// `ws(s)://hôte/ws?token=…` — le socket RPC.
    public var webSocketURL: URL { url(path: "/ws", webSocket: true) }
    /// `http(s)://hôte/api/server-info?token=…`.
    public var serverInfoURL: URL { url(path: "/api/server-info", webSocket: false) }
    /// `http(s)://hôte/?token=…` — l'interface web officielle (vue de secours).
    public var webUIURL: URL { url(path: "/", webSocket: false) }

    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func url(path: String, webSocket: Bool) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            preconditionFailure("URL d'hôte invalide : \(baseURL)")
        }
        if webSocket {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        components.path = path
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? ""
        components.percentEncodedQuery = "token=\(encodedToken)"
        guard let url = components.url else {
            preconditionFailure("URL d'hôte invalide : \(baseURL)")
        }
        return url
    }
}

extension HostEndpoint: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Le token est masqué : un `print`, une interpolation ou un `dump` ne doivent jamais le révéler.
    public var description: String { "HostEndpoint(\(baseURL.absoluteString), token: ••••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["baseURL": baseURL, "token": "••••"]) }
}
