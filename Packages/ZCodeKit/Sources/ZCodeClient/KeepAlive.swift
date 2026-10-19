import Foundation
import Synchronization
import ZCodeRPC

/// Ping périodique : sans réponse dans le délai, la connexion est déclarée perdue. Couvre le socket resté à moitié
/// ouvert (Mac en veille, changement de réseau), qui sinon n'échouerait jamais.
public enum KeepAlive {
    /// Boucle jusqu'à l'annulation (renvoie `nil`) ou jusqu'au premier ping refusé ou sans réponse.
    public static func run(
        every interval: Duration,
        timeout: Duration,
        ping: @escaping @Sendable () async throws -> Void
    ) async -> TransportError? {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return nil
            }
            if let failure = await attempt(ping, timeout: timeout) {
                return failure
            }
        }
        return nil
    }

    /// Un ping borné dans le temps. Le ping n'est pas annulable (`sendPing`) : la course est arbitrée par un
    /// drapeau unique plutôt que par un groupe de tâches, qui attendrait le ping bloqué.
    private static func attempt(_ ping: @escaping @Sendable () async throws -> Void, timeout: Duration) async -> TransportError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<TransportError?, Never>) in
            let settled = Once()
            Task {
                do {
                    try await ping()
                    if settled.claim() { continuation.resume(returning: nil) }
                } catch {
                    if settled.claim() {
                        continuation.resume(returning: .connectionFailed("ping refusé (\(error.localizedDescription))"))
                    }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if settled.claim() {
                    continuation.resume(returning: .connectionFailed("aucune réponse au ping en \(timeout)"))
                }
            }
        }
    }
}

/// Vrai une seule fois.
private final class Once: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
