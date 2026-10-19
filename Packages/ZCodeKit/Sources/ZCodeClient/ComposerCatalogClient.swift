import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Catalogues du composeur, lus comme ZCode Web : commandes du projet sur `zcode-session` (le navigateur passe par
/// `IZCodeSessionService.readWorkspacePresentation`, qui délègue à l'agent), skills sur `zcode-agent`, droit aux
/// workflows dynamiques sur `coding-plan-subscription`. Lectures seules, sans écoute ; un objet unique dans un tableau,
/// un champ sans valeur omis.
public struct ComposerCatalogClient: Sendable {
    /// Décision D1 de la tâche 0 (canal du navigateur).
    public static let presentationChannel = "zcode-session"
    public static let skillsChannel = V4Protocol.agentChannel
    public static let workflowChannel = "coding-plan-subscription"

    public let client: ChannelClient
    public let workspacePath: String

    public init(client: ChannelClient, workspacePath: String) {
        self.client = client
        self.workspacePath = workspacePath
    }

    /// Commandes du panneau et mode du projet (aucune session requise).
    public func presentation() async throws -> WorkspacePresentation {
        let method = "readWorkspacePresentation"
        let value = try await call(Self.presentationChannel, method, ["workspacePath": .string(workspacePath)])
        do {
            return try WorkspacePresentation(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(Self.presentationChannel).\(method)", detail: "\(error)")
        }
    }

    /// `sessionId` : catalogue figé de cette session (erreur si l'agent ne la connaît pas) ; `nil` : scan du projet.
    public func skills(sessionId: String?) async throws -> SkillReferenceCatalog {
        let method = "getSkillReferenceCatalog"
        var params: [String: JSONValue] = ["workspacePath": .string(workspacePath)]
        if let sessionId { params["sessionId"] = .string(sessionId) }
        let value = try await call(Self.skillsChannel, method, params)
        do {
            return try SkillReferenceCatalog(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(Self.skillsChannel).\(method)", detail: "\(error)")
        }
    }

    /// Barrière des workflows dynamiques telle que l'hôte la voit (offre du serveur et choix de l'utilisateur).
    public func dynamicWorkflowConfig() async throws -> DynamicWorkflowConfig {
        let method = "getDynamicWorkflowClientConfig"
        let value = try await client.call(Self.workflowChannel, method, .array([])).jsonValue ?? .null
        do {
            return try DynamicWorkflowConfig(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(Self.workflowChannel).\(method)", detail: "\(error)")
        }
    }

    private func call(_ channel: String, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}
