import Foundation
import Observation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

/// Modèles proposés par un hôte (canal `model-selection`), tenus à jour par `onDidChange`.
@MainActor
@Observable
public final class ModelCatalog {
    public private(set) var view: ModelSelectionView?
    public private(set) var failure: String?
    private let connection: HostConnection
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var running = false
    /// Révision acceptée pour la connexion en cours ; `nil` à chaque (re)démarrage.
    @ObservationIgnored private var acceptedRevision: Int?
    @ObservationIgnored private var generation = 0

    public init(connection: HostConnection) {
        self.connection = connection
    }

    /// À l'ouverture d'une conversation et au retour au premier plan : relance si l'écoute est tombée ou si la
    /// dernière lecture de la vue a échoué (sans quoi la liste resterait vide jusqu'au prochain `onDidChange`).
    public func startIfNeeded() async {
        guard !running || failure != nil else { return }
        await start()
    }

    public func start() async {
        generation += 1
        let generation = self.generation
        listener?.cancel()
        listener = nil
        acceptedRevision = nil
        running = true
        guard let channel = await connection.ensureConnected() else {
            guard generation == self.generation else { return }
            running = false
            failure = connection.failure?.message ?? "Hôte injoignable."
            return
        }
        guard generation == self.generation else { return }
        let client = ModelSelectionClient(client: channel)
        do {
            let changes = try await client.changes()
            guard generation == self.generation else { return }
            listener = Task { [weak self] in
                for await _ in changes {
                    await self?.reload(client, generation: generation)
                }
                self?.listenerEnded(generation: generation)
            }
            await reload(client, generation: generation)
        } catch {
            guard generation == self.generation else { return }
            running = false
            failure = "Liste des modèles indisponible : \(ConnectionFailure(error).message)"
        }
    }

    public func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        running = false
    }

    private func reload(_ client: ModelSelectionClient, generation: Int) async {
        do {
            let view = try await client.getView()
            guard generation == self.generation else { return }
            // Réponses désordonnées : seule une révision au moins égale remplace la vue de cette connexion.
            if let acceptedRevision, view.revision < acceptedRevision { return }
            acceptedRevision = view.revision
            self.view = view
            failure = nil
        } catch {
            guard generation == self.generation else { return }
            failure = "Liste des modèles indisponible : \(ConnectionFailure(error).message)"
        }
    }

    private func listenerEnded(generation: Int) {
        if generation == self.generation { running = false }
    }
}
