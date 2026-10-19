import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Refus côté client, avant tout appel : l'hôte n'applique pas ces gardes lui-même.
public enum SubagentsClientError: Error, Equatable, Sendable {
    /// Modification, suppression ou activation d'un agent qui n'est pas un fichier modifiable de l'utilisateur
    /// (valeur : nom de l'agent). Vaut aussi pour l'interrupteur d'un agent de projet, que la vue ne propose jamais.
    case readOnly(String)
    /// Réglage du modèle d'un agent qui n'est ni intégré ni de plugin (valeur : nom de l'agent) : il se règle dans
    /// son formulaire.
    case notOverridable(String)
}

/// Canal `subagents` de l'hôte : sous-agents intégrés, de l'utilisateur, de projet et de plugins. Le canal n'a aucun
/// événement (ne jamais l'écouter) ; les méthodes `disposeAll`, `prepareRuntimeState`, `readRuntimeConfig` et
/// `getPrimaryUserAgentsDirectory` ne sont pas utilisées. L'hôte relit les fichiers d'agents au début de chaque tour
/// parent (~1,5 s), sans redémarrage.
public struct SubagentsClient: Sendable {
    public static let channel = "subagents"
    public static let provider = "glm"
    public let client: ChannelClient
    /// Projet de l'hôte envoyé en portée Utilisateur (le canal en exige un).
    public let hostWorkspace: String

    public init(client: ChannelClient, hostWorkspace: String) {
        self.client = client
        self.hostWorkspace = hostWorkspace
    }

    /// Portée Utilisateur : uniquement les réglages de l'utilisateur ; Projet : tout ce que voit le runtime.
    public func list(scope: ExtensionScope) async throws -> AgentsListResult {
        let method = "list"
        let value = try await call(method, [
            "workspacePath": .string(scope.workspacePath ?? hostWorkspace),
            "provider": .string(Self.provider),
            "mode": .string(scope == .user ? "settingsUserOnly" : "allRuntimeScopes"),
        ])
        do {
            return try AgentsListResult(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(Self.channel).\(method)", detail: "\(error)")
        }
    }

    public func create(_ config: SubAgentConfig, scope: ExtensionScope) async throws -> AgentSummary {
        let method = "createAgent"
        var params: [String: JSONValue] = ["config": config.json, "provider": .string(Self.provider)]
        addScope(scope, to: &params)
        return try agent(from: try await call(method, params), method: method)
    }

    /// Enregistre `config` dans le fichier lu (`agent.path`) : l'ancien chemin est toujours envoyé, sans quoi l'hôte ne
    /// contrôle pas les collisions lors d'un renommage.
    public func update(_ agent: AgentSummary, with config: SubAgentConfig, scope: ExtensionScope) async throws -> AgentSummary {
        guard agent.isEditable else { throw SubagentsClientError.readOnly(agent.name) }
        let method = "updateAgent"
        var params: [String: JSONValue] = [
            "agentId": .string(agent.id), "oldFilePath": .string(agent.path),
            "config": config.json, "provider": .string(Self.provider),
        ]
        addScope(scope, to: &params)
        return try self.agent(from: try await call(method, params), method: method)
    }

    /// Supprime le fichier lu (`agent.path`), jamais un chemin saisi.
    public func delete(_ agent: AgentSummary) async throws {
        guard agent.isEditable else { throw SubagentsClientError.readOnly(agent.name) }
        _ = try await call("deleteAgent", ["agentId": .string(agent.id), "filePath": .string(agent.path)])
    }

    /// Seul un agent de la portée Utilisateur s'active ou se désactive. Le `enabled` renvoyé n'est pas fiable : relire
    /// la liste.
    public func setEnabled(_ agent: AgentSummary, _ enabled: Bool) async throws {
        guard agent.canToggleEnabled else { throw SubagentsClientError.readOnly(agent.name) }
        _ = try await call("setEnabled", ["agentId": .string(agent.id), "enabled": .bool(enabled)])
    }

    /// Modèle imposé à un agent intégré ou de plugin ; `nil` rétablit le modèle par défaut.
    public func setModelOverride(_ agent: AgentSummary, _ selection: ModelSelection?) async throws {
        var params: [String: JSONValue]
        let method: String
        if agent.source == .builtIn {
            method = "setBuiltInModelOverride"
            params = ["agentName": .string(agent.name)]
        } else if agent.source == .plugin {
            method = "setPluginAgentModelOverride"
            params = ["agentId": .string(agent.id)]
        } else {
            throw SubagentsClientError.notOverridable(agent.name)
        }
        if let selection { params["modelSelection"] = try V4JSON.encode(selection) }
        _ = try await call(method, params)
    }

    private func addScope(_ scope: ExtensionScope, to params: inout [String: JSONValue]) {
        params["scope"] = .string(scope.wireName)
        if let path = scope.workspacePath { params["workspacePath"] = .string(path) }
    }

    private func agent(from value: JSONValue, method: String) throws -> AgentSummary {
        guard let agent = value["agent"].flatMap(AgentSummary.init(json:)) else {
            throw AgentV4Error.malformedResponse(method: "\(Self.channel).\(method)", detail: "agent absent ou illisible")
        }
        return agent
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(Self.channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}
