import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

/// Connexion et projet communs aux modèles des Extensions (sous-agents, plugins) : leurs canaux exigent un projet de
/// l'hôte, quelle que soit la portée.
enum ExtensionsHost {
    /// Aucun projet utilisable : ni annoncé par l'hôte, ni porté par la portée.
    struct NoWorkspace: Error {}

    /// Canal vivant et projet à fournir à l'hôte : le premier que l'hôte annonce, sinon celui de la portée.
    @MainActor
    static func channelAndWorkspace(
        connection: HostConnection, scope: ExtensionScope
    ) async throws -> (channel: ChannelClient, workspace: String) {
        guard let channel = await connection.ensureConnected() else {
            throw connection.failure ?? ConnectionFailure.unreachable("connexion impossible")
        }
        guard let workspace = connection.serverInfo?.workspaces.first?.path ?? scope.workspacePath else { throw NoWorkspace() }
        return (channel, workspace)
    }

    /// Panne de connexion (hôte injoignable, connexion coupée) : seule cause d'un bandeau « Hors ligne ». Un refus de
    /// l'hôte (`remote`), l'absence de projet ou un token refusé n'en sont pas.
    static func isOffline(_ error: any Error) -> Bool {
        if error is NoWorkspace { return false }
        if case RPCError.remote = error { return false }
        return ConnectionFailure(error).isRetryable
    }

    /// Libellé d'une erreur : celui de l'absence de projet, sinon la traduction propre au canal.
    static func message(_ error: any Error, otherwise translate: (any Error) -> String) -> String {
        if error is NoWorkspace { return "l'hôte n'annonce aucun projet." }
        return translate(error)
    }
}
