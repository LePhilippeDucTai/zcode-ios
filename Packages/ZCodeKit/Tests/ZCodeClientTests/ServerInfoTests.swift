import Foundation
import Testing
import ZCodeClient
import ZCodeWire

/// Réponse HTTP simulée pour `URLSession`.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var lastURL: URL?
    nonisolated(unsafe) static var failure: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ServerInfoTests {
    /// Réponse réelle de ZCode v3.15.1 (`GET /api/server-info`).
    static let sample = Data(#"{"serverId":"Mac.localdomain","version":"3.15.1","protocolVersion":1,"authRequired":true,"workspaces":[{"path":"/Users/me/claude","label":"claude"}],"capabilities":{"desktopContinuous":true,"websocketRpc":true,"processResourceTelemetry":true}}"#.utf8)

    let endpoint = HostEndpoint(baseURL: URL(string: "https://h.ts.net")!, token: "secret")

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func decodeLaReponseReelle() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Self.sample)
        #expect(info.version == "3.15.1")
        #expect(info.protocolVersion == 1)
        #expect(info.authRequired)
        #expect(info.workspaces == [.init(path: "/Users/me/claude", label: "claude", workspaceIdentity: nil)])
        #expect(info.capabilities["websocketRpc"] == .bool(true))
    }

    @Test func recupereAvecLeToken() async throws {
        StubURLProtocol.response = (200, Self.sample)
        let info = try await ServerInfo.fetch(from: endpoint, session: session)
        #expect(info.serverId == "Mac.localdomain")
        #expect(StubURLProtocol.lastURL?.absoluteString == "https://h.ts.net/api/server-info?token=secret")
    }

    @Test func tokenRefuse() async {
        StubURLProtocol.response = (401, Data(#"{"error":"Unauthorized"}"#.utf8))
        await #expect(throws: ServerInfoError.unauthorized) { try await ServerInfo.fetch(from: endpoint, session: session) }
    }

    @Test func erreurServeur() async {
        StubURLProtocol.response = (500, Data())
        await #expect(throws: ServerInfoError.httpStatus(500)) { try await ServerInfo.fetch(from: endpoint, session: session) }
    }

    @Test func erreurReseauSansToken() async {
        StubURLProtocol.failure = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://h.ts.net/api/server-info?token=secret")!,
        ])
        defer { StubURLProtocol.failure = nil }
        do {
            _ = try await ServerInfo.fetch(from: endpoint, session: session)
            Issue.record("une erreur était attendue")
        } catch {
            guard case ServerInfoError.network = error else {
                Issue.record("erreur inattendue : \(type(of: error))")
                return
            }
            #expect(!"\(error)".contains("secret"))
            #expect(!String(reflecting: error).contains("secret"))
        }
    }

    @Test func annulationPropageeSansToken() async {
        StubURLProtocol.failure = URLError(.cancelled, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://h.ts.net/api/server-info?token=secret")!,
        ])
        defer { StubURLProtocol.failure = nil }
        await #expect(throws: CancellationError.self) { try await ServerInfo.fetch(from: endpoint, session: session) }
    }

    @Test func reponseIllisible() async {
        StubURLProtocol.response = (200, Data("<html>".utf8))
        await #expect(throws: ServerInfoError.invalidResponse) { try await ServerInfo.fetch(from: endpoint, session: session) }
    }
}
