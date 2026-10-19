import Foundation
import Observation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Ce qu'il faut pour joindre un hôte (remplaçable dans les tests).
public struct ConnectionDependencies: Sendable {
    public var fetchServerInfo: @Sendable (HostEndpoint) async throws -> ServerInfo
    public var openChannel: @Sendable (HostEndpoint) async throws -> ChannelClient
    public var sleep: @Sendable (Duration) async throws -> Void
    public var clientId: String
    public var appVersion: String

    public init(
        fetchServerInfo: @escaping @Sendable (HostEndpoint) async throws -> ServerInfo,
        openChannel: @escaping @Sendable (HostEndpoint) async throws -> ChannelClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        clientId: String,
        appVersion: String
    ) {
        self.fetchServerInfo = fetchServerInfo
        self.openChannel = openChannel
        self.sleep = sleep
        self.clientId = clientId
        self.appVersion = appVersion
    }

    public static func live(clientId: String, appVersion: String) -> ConnectionDependencies {
        ConnectionDependencies(
            fetchServerInfo: { try await ServerInfo.fetch(from: $0) },
            openChannel: { try await ZCodeConnector.connect(to: $0) },
            sleep: { try await Task.sleep(for: $0) },
            clientId: clientId,
            appVersion: appVersion
        )
    }
}

/// Raison d'une connexion impossible, présentable à l'utilisateur (jamais d'URL : elle contient le token).
public enum ConnectionFailure: Error, Equatable, Sendable {
    case missingToken
    case unauthorized
    case unreachable(String)
    case unsupportedProtocol(Int)
    case serverError(String)

    public init(_ error: any Error) {
        switch error {
        case let failure as ConnectionFailure: self = failure
        case ServerInfoError.unauthorized: self = .unauthorized
        case RPCError.transport(.unauthorized): self = .unauthorized
        case ServerInfoError.network(let detail): self = .unreachable(detail)
        case RPCError.transport(.connectionFailed(let detail)): self = .unreachable(detail)
        case RPCError.connectionClosed: self = .unreachable("connexion fermée")
        case ConnectorError.timeout: self = .unreachable("délai de connexion dépassé")
        case AgentV4Error.unsupportedProtocol(let version): self = .unsupportedProtocol(version)
        // 502/503/504 : `tailscale serve` répond ainsi tant que zcode-web redémarre (mise à jour, nouveau token).
        case ServerInfoError.httpStatus(let status) where (502...504).contains(status): self = .unreachable("HTTP \(status)")
        case ServerInfoError.httpStatus(let status): self = .serverError("HTTP \(status)")
        default: self = .serverError(String(describing: error))
        }
    }

    public var message: String {
        switch self {
        case .missingToken:
            "Token absent de cet iPhone : modifie l'hôte pour le saisir à nouveau."
        case .unauthorized:
            "Token refusé par l'hôte (a-t-il été régénéré ?)."
        case .unreachable(let detail):
            "Hôte injoignable (\(detail)). Vérifie que le Mac est allumé et que Tailscale est actif."
        case .unsupportedProtocol(let version):
            "Version du protocole ZCode non prise en charge (\(version)) : utilise l'interface web en attendant une mise à jour de l'app."
        case .serverError(let detail):
            "Erreur du serveur ZCode : \(detail)"
        }
    }

    /// Seules les erreurs réseau justifient un nouvel essai automatique.
    public var isRetryable: Bool {
        if case .unreachable = self { true } else { false }
    }
}

/// Connexion à un hôte : `server-info`, canal RPC, handshake V4, puis reconnexion progressive si le canal meurt.
@MainActor
@Observable
public final class HostConnection {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed(ConnectionFailure)
    }

    /// Attente avant chaque tentative (spec : 0, 1, 2, 5, 10 puis 30 s).
    public static let retryDelays: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    public var host: Host
    public private(set) var state: State = .idle
    public private(set) var serverInfo: ServerInfo?
    public private(set) var hello: HelloMessage?
    private let endpoint: HostEndpoint?
    private let dependencies: ConnectionDependencies
    @ObservationIgnored private var client: ChannelClient?
    /// Seule opération de connexion en vol (tentative unique ou reconnexion progressive) : les appels la partagent.
    @ObservationIgnored private var operation: Task<ChannelClient?, Never>?
    /// Incrémentée par `disconnect()` : une tentative dépassée ferme son canal sans toucher à l'état.
    @ObservationIgnored private var generation = 0

    public init(host: Host, endpoint: HostEndpoint?, dependencies: ConnectionDependencies) {
        self.host = host
        self.endpoint = endpoint
        self.dependencies = dependencies
    }

    /// Projets annoncés par le serveur, puis projets ajoutés à la main, sans doublon.
    public var workspaces: [String] {
        var seen = Set<String>()
        return ((serverInfo?.workspaces.map(\.path) ?? []) + host.manualWorkspaces).filter { seen.insert($0).inserted }
    }

    public var versionWarning: String? {
        guard let version = serverInfo?.version, version != V4Protocol.lastTestedServerVersion else { return nil }
        return "ZCode \(version) sur l'hôte (version testée : \(V4Protocol.lastTestedServerVersion)) : "
            + "certains éléments peuvent s'afficher comme non pris en charge."
    }

    public var failure: ConnectionFailure? {
        if case .failed(let failure) = state { failure } else { nil }
    }

    /// Une tentative de connexion (ferme le canal précédent), ou rejoint celle déjà en cours. Elle s'exécute hors de la
    /// tâche de l'appelant : quitter l'écran qui l'a demandée ne l'interrompt pas.
    public func connect() async {
        if let operation {
            _ = await operation.value
            return
        }
        _ = await run { await self.attempt() }
    }

    public func isAlive() async -> Bool {
        guard let client else { return false }
        return await Self.isReady(client)
    }

    /// Canal vivant, en se reconnectant si besoin ; les appels simultanés partagent la même opération.
    public func ensureConnected() async -> ChannelClient? {
        if let client, await Self.isReady(client) { return client }
        if let operation { return await operation.value }
        return await run { await self.reconnectWithBackoff() }
    }

    public func agent(workspace: String) async -> AgentV4? {
        guard let client = await ensureConnected() else { return nil }
        return AgentV4(client: client, workspacePath: workspace)
    }

    public func disconnect() async {
        generation += 1
        operation?.cancel()
        operation = nil
        let previous = client
        client = nil
        state = .idle
        await previous?.close()
    }

    private func run(_ body: @escaping @MainActor () async -> ChannelClient?) async -> ChannelClient? {
        let task = Task { await body() }
        operation = task
        let result = await task.value
        if operation == task { operation = nil }
        return result
    }

    private struct Superseded: Error {}

    private func attempt() async -> ChannelClient? {
        let generation = self.generation
        let previous = client
        client = nil
        await previous?.close()
        guard generation == self.generation else { return nil }
        guard let endpoint else {
            state = .failed(.missingToken)
            return nil
        }
        state = .connecting
        var opened: ChannelClient?
        do {
            let info = try await dependencies.fetchServerInfo(endpoint)
            guard generation == self.generation else { throw Superseded() }
            serverInfo = info
            let channel = try await dependencies.openChannel(endpoint)
            opened = channel
            guard generation == self.generation else { throw Superseded() }
            // Le handshake est propre à la connexion : l'espace de travail n'intervient pas.
            let hello = try await AgentV4(client: channel, workspacePath: "")
                .handshake(clientId: dependencies.clientId, appVersion: dependencies.appVersion)
            guard generation == self.generation else { throw Superseded() }
            self.hello = hello
            client = channel
            state = .connected
            return channel
        } catch {
            await opened?.close()
            if generation == self.generation, !(error is Superseded) {
                state = .failed(ConnectionFailure(error))
            }
            return nil
        }
    }

    private func reconnectWithBackoff() async -> ChannelClient? {
        let generation = self.generation
        for delay in Self.retryDelays {
            if delay > .zero {
                do { try await dependencies.sleep(delay) } catch { return nil }
            }
            guard generation == self.generation, !Task.isCancelled else { return nil }
            if let channel = await attempt() { return channel }
            if case .failed(let failure) = state, !failure.isRetryable { return nil }
        }
        return nil
    }

    private static func isReady(_ client: ChannelClient) async -> Bool {
        do {
            try await client.ready()
            return true
        } catch {
            return false
        }
    }
}
