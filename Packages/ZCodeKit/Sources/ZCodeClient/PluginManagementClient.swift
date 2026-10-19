import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Canal `plugin-management` de l'hôte : marketplaces, catalogue, installation et configuration des plugins. L'hôte
/// relaie chaque appel vers son processus CLI dédié aux plugins. Aucun événement n'est utilisé (jamais
/// `onDynamicPluginOperationProgress`) ; un échec d'opération arrive dans les `diagnostics` d'une réponse de succès,
/// que l'appelant doit traiter (`failure`, `isError`). L'annulation passe par `cancel` : annuler l'appel RPC ne fait
/// rien côté hôte. Les plugins ne sont pris en compte que par les nouvelles sessions.
public struct PluginManagementClient: Sendable {
    public static let channel = "plugin-management"
    public let client: ChannelClient
    /// Projet de l'hôte envoyé en portée Utilisateur (le canal en exige un).
    public let hostWorkspace: String

    public init(client: ChannelClient, hostWorkspace: String) {
        self.client = client
        self.hostWorkspace = hostWorkspace
    }

    // MARK: Lecture

    /// Portée Utilisateur : ignore le projet ; Projet : fusionne `<projet>/.zcode/config.json`.
    public func overview(scope: ExtensionScope) async throws -> PluginsOverview {
        let method = "getPluginsOverview"
        let value = try await call(method, base(scope, ["configScope": .string(scope.wireName)]))
        return try decode(method) { () throws(V4DecodingError) in try PluginsOverview(json: value) }
    }

    public func list(scope: ExtensionScope) async throws -> PluginsList {
        let method = "listPlugins"
        let value = try await call(method, base(scope, ["configScope": .string(scope.wireName)]))
        return try decode(method) { () throws(V4DecodingError) in try PluginsList(json: value) }
    }

    public func describe(_ plugin: AvailablePlugin, scope: ExtensionScope) async throws -> PluginDescription {
        let method = "describePlugin"
        let value = try await call(method, base(scope, [
            "marketplace": .string(plugin.marketplace), "pluginName": .string(plugin.name),
        ]))
        return try decode(method) { () throws(V4DecodingError) in try PluginDescription(json: value) }
    }

    // MARK: Installation

    /// Installe toujours pour l'utilisateur (l'hôte ignore la portée) ; `scope` ne désigne que le projet de contexte.
    public func install(_ plugin: AvailablePlugin, operationId: String, scope: ExtensionScope) async throws -> PluginInstallResult {
        let method = "installPlugin"
        let value = try await call(method, base(scope, [
            "marketplace": .string(plugin.marketplace), "pluginName": .string(plugin.name),
            "operationId": .string(operationId),
        ]))
        return try decode(method) { () throws(V4DecodingError) in try PluginInstallResult(json: value) }
    }

    /// Toujours avec `pluginId` : sans lui, l'hôte mettrait à jour tous les plugins.
    public func update(pluginId: String, scope: ExtensionScope) async throws -> PluginInstallResult {
        let method = "updatePlugin"
        let value = try await call(method, base(scope, ["pluginId": .string(pluginId)]))
        return try decode(method) { () throws(V4DecodingError) in try PluginInstallResult(json: value) }
    }

    /// Supprime cache, données et configuration. Un plugin intégré est seulement masqué (`restoreBuiltin` le rétablit).
    public func uninstall(pluginId: String, scope: ExtensionScope) async throws -> [PluginDiagnostic] {
        try await diagnostics("uninstallPlugin", base(scope, ["pluginId": .string(pluginId)]))
    }

    public func restoreBuiltin(pluginId: String, scope: ExtensionScope) async throws -> [PluginDiagnostic] {
        try await diagnostics("restoreBuiltinPlugin", base(scope, ["pluginId": .string(pluginId)]))
    }

    // MARK: Réglages

    /// Active ou désactive dans la portée donnée (`user` écrit `~/.zcode/cli/config.json`, `workspace` le projet).
    public func setEnabled(pluginId: String, _ enabled: Bool, scope: ExtensionScope) async throws {
        _ = try await call("setPluginEnabled", base(scope, [
            "pluginId": .string(pluginId), "enabled": .bool(enabled), "scope": .string(scope.wireName),
        ]))
    }

    /// Correctif de configuration : seulement `options` (valeurs modifiées) et `clearing` (clés à effacer, omis si vide).
    public func configure(pluginId: String, options: [String: JSONValue], clearing: [String],
                          scope: ExtensionScope) async throws -> [PluginDiagnostic] {
        var params: [String: JSONValue] = [
            "pluginId": .string(pluginId), "options": .object(options), "scope": .string(scope.wireName),
        ]
        if !clearing.isEmpty { params["clearOptionKeys"] = .array(clearing.map(JSONValue.string)) }
        return try await diagnostics("configurePlugin", base(scope, params))
    }

    public func resetConfig(pluginId: String, scope: ExtensionScope) async throws -> [PluginDiagnostic] {
        try await diagnostics("resetPluginConfig", base(scope, [
            "pluginId": .string(pluginId), "scope": .string(scope.wireName),
        ]))
    }

    // MARK: Sources et annulation

    /// `dryRun` n'est envoyé que s'il vaut `true` (résumé fictif `id: "dry-run"`) ; `operationId` seulement s'il existe.
    public func addMarketplace(source: String, dryRun: Bool, operationId: String?,
                               scope: ExtensionScope) async throws -> MarketplaceMutationResult {
        let method = "addPluginMarketplace"
        var params: [String: JSONValue] = ["source": .string(source)]
        if dryRun { params["dryRun"] = .bool(true) }
        if let operationId { params["operationId"] = .string(operationId) }
        let value = try await call(method, base(scope, params))
        return try decode(method) { () throws(V4DecodingError) in try MarketplaceMutationResult(json: value) }
    }

    /// Retire une source (les deux officielles sont recréées). Les diagnostics reviennent à l'appelant : une erreur est
    /// un refus.
    public func removeMarketplace(id: String, scope: ExtensionScope) async throws -> [PluginDiagnostic] {
        try await diagnostics("removePluginMarketplace", base(scope, ["marketplace": .string(id)]))
    }

    /// `id` absent : toutes les sources.
    public func refreshMarketplace(id: String?, operationId: String, scope: ExtensionScope) async throws -> MarketplaceMutationResult {
        let method = "updatePluginMarketplace"
        var params: [String: JSONValue] = ["operationId": .string(operationId)]
        if let id { params["marketplace"] = .string(id) }
        let value = try await call(method, base(scope, params))
        return try decode(method) { () throws(V4DecodingError) in try MarketplaceMutationResult(json: value) }
    }

    /// `false` si l'opération est déjà finie ou inconnue. Seul appel sans `workspacePath`.
    public func cancel(operationId: String) async throws -> Bool {
        let method = "cancelPluginOperation"
        let value = try await call(method, ["operationId": .string(operationId)])
        guard let cancelled = value["cancelled"]?.boolValue else {
            throw AgentV4Error.malformedResponse(method: "\(Self.channel).\(method)", detail: "cancelled absent")
        }
        return cancelled
    }

    // MARK: Internes

    /// `workspacePath` (projet de la portée, sinon projet de l'hôte) ajouté aux paramètres de la méthode.
    private func base(_ scope: ExtensionScope, _ params: [String: JSONValue]) -> [String: JSONValue] {
        var params = params
        params["workspacePath"] = .string(scope.workspacePath ?? hostWorkspace)
        return params
    }

    private func diagnostics(_ method: String, _ params: [String: JSONValue]) async throws -> [PluginDiagnostic] {
        let value = try await call(method, params)
        guard value.objectValue != nil else {
            throw AgentV4Error.malformedResponse(method: "\(Self.channel).\(method)", detail: "objet attendu")
        }
        return PluginDiagnostic.list(value["diagnostics"])
    }

    private func decode<T>(_ method: String, _ body: () throws(V4DecodingError) -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw AgentV4Error.malformedResponse(method: "\(Self.channel).\(method)", detail: "\(error)")
        }
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(Self.channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}
