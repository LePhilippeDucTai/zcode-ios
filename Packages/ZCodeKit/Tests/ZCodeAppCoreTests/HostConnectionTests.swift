import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport

@MainActor
struct HostConnectionTests {
    @Test func connexionReussie() async throws {
        let servers = ServerQueue([try await readyServer()])
        let host = Host(name: "Mac", baseURL: URL(string: "https://mac.ts.net")!, manualWorkspaces: [testWorkspacePath, "/tmp/autre"])
        let connection = HostConnection(host: host, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        await connection.connect()
        #expect(connection.state == .connected)
        #expect(connection.hello?.protocolVersion == 3)
        #expect(connection.workspaces == [testWorkspacePath, "/tmp/autre"])     // serveur puis manuels, sans doublon
        #expect(connection.versionWarning == nil)
        #expect(await connection.isAlive())
    }

    @Test func tokenManquant() async {
        let connection = HostConnection(host: testHost, endpoint: nil, dependencies: makeDependencies(servers: ServerQueue([])))
        await connection.connect()
        #expect(connection.state == .failed(.missingToken))
    }

    @Test func protocoleInconnu() async throws {
        let servers = ServerQueue([try await readyServer(protocolVersion: 4)])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        await connection.connect()
        #expect(connection.state == .failed(.unsupportedProtocol(4)))
        #expect(await connection.isAlive() == false)
        #expect(ConnectionFailure.unsupportedProtocol(4).message.contains("interface web"))
    }

    @Test func versionPlusRecenteSignalee() async throws {
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: servers, serverInfo: { makeServerInfo(version: "3.16.0") }))
        await connection.connect()
        #expect(connection.state == .connected)
        #expect(connection.versionWarning?.contains("3.16.0") == true)
    }

    @Test func pasDeReessaiSurTokenRefuse() async {
        let servers = ServerQueue([])
        let sleeps = Recorder<Duration>()
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: servers, sleeps: sleeps, serverInfo: { throw ServerInfoError.unauthorized }))
        #expect(await connection.ensureConnected() == nil)
        #expect(connection.state == .failed(.unauthorized))
        #expect(sleeps.all.isEmpty)
        #expect(servers.opened == 0)
    }

    @Test func attenteProgressiveSurErreurReseau() async throws {
        let attempts = Counter()
        let sleeps = Recorder<Duration>()
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(
            servers: servers, sleeps: sleeps,
            serverInfo: {
                if attempts.next() <= 2 { throw ServerInfoError.network("hors ligne") }
                return makeServerInfo()
            }))
        #expect(await connection.ensureConnected() != nil)
        #expect(sleeps.all == [.seconds(1), .seconds(2)])
        #expect(connection.state == .connected)
    }

    @Test func reconnexionApresPerte() async throws {
        let first = try await readyServer()
        let servers = ServerQueue([first, try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        await connection.connect()
        first.transport.finish()                                                  // le serveur ferme la connexion
        _ = try await eventually { await connection.isAlive() ? nil : true }
        #expect(await connection.ensureConnected() != nil)
        #expect(servers.opened == 2)
        #expect(connection.state == .connected)
    }

    @Test func reconnexionsSimultaneesMutualisees() async throws {
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        async let first = connection.ensureConnected()
        async let second = connection.ensureConnected()
        let (a, b) = await (first, second)
        #expect(a != nil && b != nil)
        #expect(servers.opened == 1)
    }

    @Test func connexionEtReconnexionSimultaneesMutualisees() async throws {
        let servers = ServerQueue([try await readyServer(), try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        async let manual: Void = connection.connect()                            // « Réessayer » sur l'écran de l'hôte
        async let automatic = connection.ensureConnected()                       // une liste qui se reconnecte
        let (_, channel) = await (manual, automatic)
        #expect(channel != nil)
        #expect(servers.opened == 1)
        #expect(connection.state == .connected)
    }

    @Test func quitterLEcranPendantLaConnexionNEstPasUnePanne() async throws {
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: servers, serverInfoDelay: .milliseconds(200)))
        let screen = Task { await connection.connect() }                         // `.task` de l'écran de l'hôte
        try await Task.sleep(for: .milliseconds(50))
        screen.cancel()                                                          // l'utilisateur revient en arrière
        await screen.value
        _ = try await eventually { connection.state == .connecting ? nil : true }
        #expect(connection.state == .connected)
    }

    @Test func deconnexionPendantLaConnexion() async throws {
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: servers, serverInfoDelay: .milliseconds(200)))
        let attempt = Task { await connection.connect() }
        try await Task.sleep(for: .milliseconds(50))
        await connection.disconnect()                                            // adresse ou token modifiés
        await attempt.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(connection.state == .idle)
        #expect(await connection.isAlive() == false)
        #expect(servers.opened == 0)
    }

    @Test func erreurServeurTemporaireReessayee() async throws {
        #expect(ConnectionFailure(ServerInfoError.httpStatus(502)).isRetryable)   // tailscale serve, zcode-web redémarre
        #expect(ConnectionFailure(ServerInfoError.httpStatus(503)).isRetryable)
        #expect(!ConnectionFailure(ServerInfoError.httpStatus(404)).isRetryable)
        let attempts = Counter()
        let servers = ServerQueue([try await readyServer()])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(
            servers: servers,
            serverInfo: {
                if attempts.next() <= 2 { throw ServerInfoError.httpStatus(502) }
                return makeServerInfo()
            }))
        #expect(await connection.ensureConnected() != nil)
    }
}
