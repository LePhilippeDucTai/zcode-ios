import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Workflows enregistrés (`*.dwf.ts`), lus sur `zcode-agent` : deux appels, projet puis global (l'hôte ne fusionne
/// jamais). Lecture seule ; un objet unique dans un tableau, un champ sans valeur omis.
public struct SavedWorkflowsClient: Sendable {
    public let client: ChannelClient
    public let workspacePath: String

    public init(client: ChannelClient, workspacePath: String) {
        self.client = client
        self.workspacePath = workspacePath
    }

    /// Workflows du projet (`workspacePath`, sans `scope`).
    public func project() async throws -> SavedWorkflowList {
        try await list(["workspacePath": .string(workspacePath)])
    }

    /// Workflows de l'utilisateur (`scope: "global"`, sans `workspacePath`).
    public func global() async throws -> SavedWorkflowList {
        try await list(["scope": .string("global")])
    }

    private func list(_ params: [String: JSONValue]) async throws -> SavedWorkflowList {
        let method = "listSavedWorkflows"
        let value = try await client.call(V4Protocol.agentChannel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
        do {
            return try SavedWorkflowList(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(V4Protocol.agentChannel).\(method)", detail: "\(error)")
        }
    }
}
