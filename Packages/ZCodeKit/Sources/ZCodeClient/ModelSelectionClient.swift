import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Canal `model-selection` de l'hôte (service global, sans espace de travail).
public struct ModelSelectionClient: Sendable {
    public static let channel = "model-selection"
    public let client: ChannelClient

    public init(client: ChannelClient) {
        self.client = client
    }

    /// `getView([{selection}])` ; la sélection n'influe que sur des champs que l'app n'utilise pas.
    public func getView(selection: ModelSelection? = nil) async throws -> ModelSelectionView {
        let selectionJSON = try selection.map { try V4JSON.encode($0) } ?? .null
        let value = try await client.call(Self.channel, "getView", .array([RPCValue(.object(["selection": selectionJSON]))]))
        do {
            return try ModelSelectionView(json: value.jsonValue ?? .null)
        } catch {
            throw AgentV4Error.malformedResponse(method: "model-selection.getView", detail: "\(error)")
        }
    }

    /// Signal de changement (`onDidChange`, sans argument) : relire la vue avec `getView`. Le flux se termine avec
    /// la connexion ; un seul signal en attente suffit.
    public func changes() async throws -> AsyncStream<Void> {
        let raw = try await client.listen(Self.channel, "onDidChange")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let relay = Task {
            for await _ in raw { continuation.yield() }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }
}
