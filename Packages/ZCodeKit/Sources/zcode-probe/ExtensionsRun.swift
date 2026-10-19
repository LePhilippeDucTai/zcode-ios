import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// `zcode-probe extensions` : contrat réel des canaux `subagents` et `plugin-management`, sans aucun prompt (sauf
/// `--invoke`, ≈ 6 appels au modèle observés). Seuls des noms jetables sont créés, dans un espace de travail sous
/// `.zcode-check` (garde de `ProbeOptions`) ; le modèle d'Explore est rétabli à sa valeur lue. Un relevé de chaque
/// étape est écrit par `ProbeOutput` (`--record`) : identifiants, états et clés seulement, jamais les invites des vrais
/// agents ni la valeur de l'option sensible. Aucune écoute : le canal `subagents` n'a pas d'événement, et
/// `onDynamicPluginOperationProgress` est hors périmètre. Le nettoyage final s'exécute même après un échec.
struct ExtensionsRun {
    static let clientId = "client-zcode-probe-extensions"
    static let agentName = "zcode-ios-probe-agent"
    static let renamedAgentName = "zcode-ios-probe-agent-v2"
    static let pluginName = "zcode-ios-probe"
    static let marketplaceId = "zcode-ios-probe-market"
    static let pluginId = "\(pluginName)@\(marketplaceId)"
    static let builtInIds = ["built-in:built-in:general-purpose", "built-in:built-in:explore"]
    /// Valeur factice de l'option sensible (même marqueur que `Probe/plugins-lifecycle.json`) : l'hôte ne la renvoie
    /// jamais et la sonde ne l'écrit nulle part ; `grep -rl` de ce marqueur dans `~/.zcode` doit ensuite ne rien trouver.
    static let fakeSensitiveValue = "valeur-factice-ne-pas-conserver"
    /// L'outil est nommé : « Réponds uniquement PONG. » seul faisait répondre l'agent principal sans déléguer (3.15.1).
    static let prompt = "@\(renamedAgentName) Utilise l'outil Agent pour lancer le sous-agent \(renamedAgentName), "
        + "puis renvoie sa réponse telle quelle."

    let endpoint: HostEndpoint
    let workspace: String
    let marketplace: String
    let invoke: Bool
    let output: ProbeOutput
    var invokeTimeout: Duration = .seconds(120)

    /// Ce qui reste à défaire si la sonde s'interrompt.
    private struct Resources {
        /// Explore et sa surcharge lue avant la sonde (`nil` = aucune), tant qu'elle n'est pas rétablie.
        var exploreRestore: (agent: AgentSummary, selection: ModelSelection?)?
        var sessionId: String?
        var conversation: TopicFeed<ConversationSnapshot>?
    }

    private var scope: ExtensionScope { .workspace(workspace) }

    func run() async -> CheckReport {
        var report = CheckReport()
        guard let client = await runStep("connexion WebSocket", &report, { try await ZCodeConnector.connect(to: endpoint) }) else {
            return report
        }
        let agents = SubagentsClient(client: client, hostWorkspace: workspace)
        let plugins = PluginManagementClient(client: client, hostWorkspace: workspace)
        var resources = Resources()
        await runStep("ménage préalable", &report) { () async throws -> Void in
            let removed = try await removeLeftovers(agents, plugins)
            print("  → \(removed.isEmpty ? "aucun reste" : "retiré : " + removed.joined(separator: ", "))")
        }
        await exerciseSubagents(agents, client: client, &report, &resources)
        await exercisePlugins(plugins, client: client, &report)
        await cleanUp(agents, plugins, client: client, &report, resources)
        await client.close()
        return report
    }

    // MARK: - Sous-agents

    private func exerciseSubagents(_ agents: SubagentsClient, client: ChannelClient, _ report: inout CheckReport,
                                   _ resources: inout Resources) async {
        let userList = await runStep("sous-agents : liste Utilisateur (intégrés, portée disponible)", &report) {
            () async throws -> AgentsListResult in
            let list = try await agents.list(scope: .user)
            await emit("subagents.list.user", Self.summary(of: list))
            let missing = Self.builtInIds.filter { id in !list.agents.contains { $0.id == id } }
            guard missing.isEmpty else { throw CheckFailure("intégrés absents : \(missing)") }
            guard list.userScopeAvailable else {
                throw CheckFailure("portée Utilisateur indisponible (\(list.userScopeReason ?? "sans motif"))")
            }
            return list
        }

        let config = Self.agentConfig(name: Self.agentName)
        let created = await runStep("sous-agents : création (projet), présent et modifiable", &report) {
            () async throws -> AgentSummary in
            let agent = try await agents.create(config, scope: scope)
            let listed = try await listedAgent(agents) { $0.id == agent.id }
            await emit("subagents.createAgent", Self.summary(of: listed))
            guard listed.isEditable, listed.scope == .workspace else {
                throw CheckFailure("non modifiable (source \(listed.source.rawValue), portée \(listed.scope.rawValue))")
            }
            guard listed.path == "\(workspace)/.zcode/agents/\(Self.agentName).md" else {
                throw CheckFailure("fichier inattendu : \(listed.path)")
            }
            return listed
        }

        var renamed: AgentSummary?
        if let created {
            renamed = await runStep("sous-agents : renommage (oldFilePath), nouveau nom seul présent", &report) {
                () async throws -> AgentSummary in
                var next = SubAgentConfig(created)
                next.name = Self.renamedAgentName
                _ = try await agents.update(created, with: next, scope: scope)
                let list = try await agents.list(scope: scope)
                await emit("subagents.updateAgent", Self.summary(of: list))
                guard let agent = list.agents.first(where: { $0.name == Self.renamedAgentName && $0.isEditable }) else {
                    throw CheckFailure("\(Self.renamedAgentName) absent")
                }
                guard !list.agents.contains(where: { $0.id == created.id || $0.name == Self.agentName }) else {
                    throw CheckFailure("l'ancien nom est encore listé")
                }
                return agent
            }
        }

        if let userList {
            await exerciseExploreModel(agents, client: client, list: userList, &report, &resources)
        }

        if invoke, let renamed {
            await invokeAgent(renamed, client: client, &report, &resources)
        }

        if let target = renamed ?? created {
            await runStep("sous-agents : suppression, absent de la liste", &report) {
                try await agents.delete(target)
                let list = try await agents.list(scope: scope)
                await emit("subagents.deleteAgent", Self.summary(of: list))
                guard !list.agents.contains(where: { Self.isDisposable($0.name) }) else {
                    throw CheckFailure("sous-agent jetable encore listé")
                }
            }
        }
    }

    /// Modèle d'Explore : surcharge lue, remplacée par le choix par défaut de l'hôte, vérifiée, puis rétablie.
    private func exerciseExploreModel(_ agents: SubagentsClient, client: ChannelClient, list: AgentsListResult,
                                      _ report: inout CheckReport, _ resources: inout Resources) async {
        guard let explore = await runStep("modèle d'Explore : surcharge actuelle lue", &report, { () async throws -> AgentSummary in
            guard let explore = list.agents.first(where: { $0.source == .builtIn && $0.name == "Explore" }) else {
                throw CheckFailure("Explore absent")
            }
            await emit("explore.before", Self.json(explore.modelSelectionOverride))
            return explore
        }) else { return }
        let original = explore.modelSelectionOverride
        guard let preferred = await runStep("modèle d'Explore : preferredSelection de model-selection.getView", &report, {
            () async throws -> ModelSelection in
            guard let preferred = try await ModelSelectionClient(client: client).getView().preferredSelection else {
                throw CheckFailure("preferredSelection absent")
            }
            await emit("model-selection.preferredSelection", Self.json(preferred))
            return preferred
        }) else { return }
        if preferred == original {
            report.record("modèle d'Explore : valeur posée", .warning("identique à la surcharge actuelle"))
        }

        resources.exploreRestore = (explore, original)
        await runStep("modèle d'Explore : surcharge posée, relue dans la liste Utilisateur", &report) {
            try await agents.setModelOverride(explore, preferred)
            let override = try await exploreOverride(agents)
            await emit("explore.override", Self.json(override))
            guard override == preferred else { throw CheckFailure("relu : \(Self.describe(override))") }
        }
        if await restoreExplore(agents, explore, original, &report) {
            resources.exploreRestore = nil
        }
    }

    /// Rétablit la surcharge lue (ou l'efface s'il n'y en avait pas) et la relit ; `true` si elle est revenue.
    private func restoreExplore(_ agents: SubagentsClient, _ explore: AgentSummary, _ original: ModelSelection?,
                                _ report: inout CheckReport) async -> Bool {
        await runStep("modèle d'Explore : valeur d'avant rétablie (\(Self.describe(original)))", &report) {
            () async throws -> Bool in
            try await agents.setModelOverride(explore, original)
            let override = try await exploreOverride(agents)
            await emit("explore.after", Self.json(override))
            guard override == original else { throw CheckFailure("relu : \(Self.describe(override))") }
            return true
        } ?? false
    }

    private func exploreOverride(_ agents: SubagentsClient) async throws -> ModelSelection? {
        let list = try await agents.list(scope: .user)
        guard let explore = list.agents.first(where: { $0.source == .builtIn && $0.name == "Explore" }) else {
            throw CheckFailure("Explore absent")
        }
        return explore.modelSelectionOverride
    }

    /// Invocation réelle : `@<agent>` dans une session neuve de l'espace de travail ; une ligne `subagent` du bon type
    /// est attendue, puis la fin du tour, et la session est supprimée.
    private func invokeAgent(_ target: AgentSummary, client: ChannelClient, _ report: inout CheckReport,
                             _ resources: inout Resources) async {
        // L'hôte relit les fichiers d'agents par observateurs (~1,5 s).
        try? await Task.sleep(for: .seconds(3))
        let agent = AgentV4(client: client, workspacePath: workspace)
        let builder = CommandBuilder(clientId: Self.clientId)
        guard await runStep("invocation : handshake V4", &report, {
            try await agent.handshake(clientId: Self.clientId, appVersion: "zcode-probe")
        }) != nil else { return }
        guard let sessionId = await runStep("invocation : création d'une session", &report, { () async throws -> String in
            let ack = try await agent.send(builder.createSession(workspaceId: workspace))
            guard ack.isAccepted, let sessionId = ack.result?.sessionId else {
                throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
            }
            return sessionId
        }) else { return }
        resources.sessionId = sessionId
        let conversation = TopicFeed<ConversationSnapshot>(
            topic: Topic.conversation(sessionId), operations: agent.conversationOperations(sessionId: sessionId))
        resources.conversation = conversation
        guard await runStep("invocation : abonnement à la conversation", &report, { () async throws -> Void in
            try await conversation.start(frames: agent.conversationFrames())
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: conversation) }
        }) != nil else { return }
        let send = builder.sendText(sessionId: sessionId, text: Self.prompt)
        guard await runStep("invocation : envoi de « \(Self.prompt) »", &report, { () async throws -> Void in
            let ack = try await agent.send(send)
            guard ack.isAccepted else { throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil else { return }

        var answered: Set<String> = []
        let found = await runStep("invocation : ligne subagent « \(target.name) »", &report) {
            () async throws -> ConversationRow in
            try await poll(within: invokeTimeout, every: .milliseconds(500)) { () async throws -> ConversationRow? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                if let interaction = snapshot.pendingInteractions.first(where: { !answered.contains($0.interactionId) }) {
                    try await approveOnce(interaction, sessionId: sessionId, agent: agent, builder: builder)
                    answered.insert(interaction.interactionId)
                    return nil
                }
                let subagents = snapshot.rows.compactMap { row -> (ConversationRow, Subagent)? in
                    if case .subagent(let value) = row.content { (row, value) } else { nil }
                }
                if let match = subagents.first(where: { $0.1.subagentType == target.name }) { return match.0 }
                // Tour fini sans la ligne attendue : inutile d'attendre l'échéance.
                if let state = Self.turnState(in: snapshot, for: send.commandId), state != .running {
                    throw CheckFailure("tour terminé (\(state.rawValue)) sans sous-agent ; lignes du tour : "
                        + Self.turnRows(in: snapshot, for: send.commandId).joined(separator: ", "))
                }
                return nil
            }
        }
        if let found {
            await emit("conversation.subagent", found.json)
            // Fin du tour avant la suppression (le sous-agent puis l'agent principal répondent) ; non bloquant.
            let ended = try? await poll(within: .seconds(60), every: .milliseconds(500)) { () async throws -> TurnState? in
                guard let snapshot = try await feedValue(of: conversation),
                      let state = Self.turnState(in: snapshot, for: send.commandId), state != .running else { return nil }
                return state
            }
            report.record("invocation : fin du tour", ended == nil ? .warning("toujours en cours après 60 s") : .passed)
        }
        await deleteSession(agent, &report, &resources)
    }

    private func deleteSession(_ agent: AgentV4, _ report: inout CheckReport, _ resources: inout Resources) async {
        await resources.conversation?.stop()
        resources.conversation = nil
        guard let sessionId = resources.sessionId else { return }
        if await runStep("invocation : suppression de la session", &report, { () async throws -> Void in
            let ack = try await agent.send(CommandBuilder(clientId: Self.clientId).deleteSession(sessionId: sessionId))
            guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil {
            resources.sessionId = nil
        }
    }

    // MARK: - Plugins

    private func exercisePlugins(_ plugins: PluginManagementClient, client: ChannelClient, _ report: inout CheckReport) async {
        guard await runStep("plugins : aperçu Utilisateur (supported)", &report, { () async throws -> Void in
            let overview = try await plugins.overview(scope: .user)
            await emit("plugins.overview.user", Self.summary(of: overview))
            guard overview.supported else { throw CheckFailure("non pris en charge (\(overview.unsupportedReason ?? "sans motif"))") }
        }) != nil else { return }

        guard await runStep("sources : vérification (dryRun)", &report, { () async throws -> Void in
            let result = try await plugins.addMarketplace(source: marketplace, dryRun: true, operationId: nil, scope: .user)
            await emit("plugins.addPluginMarketplace.dryRun", Self.summary(of: result))
            if let failure = result.failure { throw CheckFailure(failure.message) }
            guard result.marketplace?.id == "dry-run" else { throw CheckFailure("résumé : \(result.marketplace?.id ?? "absent")") }
        }) != nil else { return }
        guard await runStep("sources : ajout", &report, { () async throws -> Void in
            let result = try await plugins.addMarketplace(source: marketplace, dryRun: false, operationId: Self.operationId(),
                                                          scope: .user)
            await emit("plugins.addPluginMarketplace", Self.summary(of: result))
            if let failure = result.failure { throw CheckFailure(failure.message) }
            guard result.marketplace?.id == Self.marketplaceId else {
                throw CheckFailure("source : \(result.marketplace?.id ?? "absente")")
            }
        }) != nil else { return }
        guard let plugin = await runStep("sources : plugin jetable au catalogue", &report, { () async throws -> AvailablePlugin in
            let overview = try await plugins.overview(scope: .user)
            guard let plugin = overview.availablePlugins.first(where: { $0.id == Self.pluginId }) else {
                throw CheckFailure("\(Self.pluginId) absent du catalogue")
            }
            return plugin
        }) else { return }
        await runStep("sources : describe (composant skill)", &report) {
            let description = try await plugins.describe(plugin, scope: .user)
            await emit("plugins.describePlugin", .array(description.components.map { .string($0.kind.rawValue) }))
            guard !description.failed, description.components.contains(where: { $0.kind == .skill }) else {
                throw CheckFailure("composants : \(description.components.map(\.kind.rawValue))")
            }
        }

        guard await runStep("installation", &report, { () async throws -> Void in
            let result = try await plugins.install(plugin, operationId: Self.operationId(), scope: .user)
            await emit("plugins.installPlugin", .array(result.installedPlugins.map { .string($0.id) }))
            if let failure = result.failure { throw CheckFailure(failure.message) }
            guard result.installedPlugins.contains(where: { $0.id == Self.pluginId }) else { throw CheckFailure("non installé") }
        }) != nil else { return }
        await runStep("installation : listé, codeFactice sensible", &report) {
            guard let info = try await plugins.list(scope: .user).plugins.first(where: { $0.id == Self.pluginId }) else {
                throw CheckFailure("absent de listPlugins")
            }
            await emit("plugins.listPlugins.userConfig", .object(Dictionary(uniqueKeysWithValues: info.userConfig.map {
                ($0.key, JSONValue.object(["type": .string($0.type), "sensitive": .bool($0.sensitive)]))
            })))
            guard info.userConfig.contains(where: { $0.key == "codeFactice" && $0.sensitive }) else {
                throw CheckFailure("codeFactice absent ou non sensible")
            }
        }

        await exerciseConfiguration(plugins, client: client, &report)

        await runStep("activation : désactivé dans le projet, activé pour l'utilisateur", &report) {
            try await plugins.setEnabled(pluginId: Self.pluginId, false, scope: scope)
            let inWorkspace = try await installed(plugins, scope: scope)
            let forUser = try await installed(plugins, scope: .user)
            await emit("plugins.setPluginEnabled", .object(["workspace": .bool(inWorkspace.enabled), "user": .bool(forUser.enabled)]))
            guard !inWorkspace.enabled, forUser.enabled else {
                throw CheckFailure("projet \(inWorkspace.enabled), utilisateur \(forUser.enabled)")
            }
        }
        await runStep("configuration : remise à zéro (projet puis utilisateur)", &report) {
            // Projet : seul l'interrupteur du projet est retiré (le plugin hérite de nouveau) ; utilisateur : toute la
            // configuration du plugin (`resetZCodePluginConfig`, v3.15.1).
            for diagnostic in try await plugins.resetConfig(pluginId: Self.pluginId, scope: scope) where diagnostic.isError {
                throw CheckFailure(diagnostic.message)
            }
            let inherited = try await installed(plugins, scope: scope)
            for diagnostic in try await plugins.resetConfig(pluginId: Self.pluginId, scope: .user) where diagnostic.isError {
                throw CheckFailure(diagnostic.message)
            }
            let options = try await configuredOptions(client)
            await emit("plugins.resetPluginConfig", options.record)
            guard inherited.enabled else { throw CheckFailure("toujours désactivé dans le projet") }
            guard options.keys.isEmpty, options.sources.isEmpty else {
                throw CheckFailure("options restantes : \(options.keys), sources \(options.sources.keys.sorted())")
            }
        }

        await runStep("sources : actualisation de la source jetable", &report) {
            let result = try await plugins.refreshMarketplace(id: Self.marketplaceId, operationId: Self.operationId(), scope: .user)
            await emit("plugins.updatePluginMarketplace", Self.summary(of: result))
            if let failure = result.failure { throw CheckFailure(failure.message) }
            guard result.marketplaces.contains(where: { $0.id == Self.marketplaceId }) else { throw CheckFailure("source absente") }
        }
        // Toutes les sources : réseau (CDN de Z.ai, GitHub) ; un échec d'une source officielle n'est qu'un avertissement.
        if let result = await runStep("sources : actualisation de toutes les sources", &report, { () async throws -> MarketplaceMutationResult in
            let result = try await plugins.refreshMarketplace(id: nil, operationId: Self.operationId(), scope: .user)
            await emit("plugins.updatePluginMarketplace.all", Self.summary(of: result))
            guard result.marketplaces.contains(where: { $0.id == Self.marketplaceId }) else { throw CheckFailure("source jetable absente") }
            return result
        }) {
            let failures = result.diagnostics.filter(\.isError).map(\.message)
                + result.marketplaces.compactMap { source in source.refreshFailure.map { "\(source.id) : \($0)" } }
            if !failures.isEmpty {
                report.record("sources : échecs d'actualisation", .warning(failures.joined(separator: " ; ")))
            }
        }

        await runStep("désinstallation et retrait de la source, absents de l'aperçu", &report) {
            for diagnostic in try await plugins.uninstall(pluginId: Self.pluginId, scope: .user) where diagnostic.isError {
                throw CheckFailure(diagnostic.message)
            }
            for diagnostic in try await plugins.removeMarketplace(id: Self.marketplaceId, scope: .user) where diagnostic.isError {
                throw CheckFailure(diagnostic.message)
            }
            let overview = try await plugins.overview(scope: .user)
            await emit("plugins.overview.after", Self.summary(of: overview))
            guard !overview.installedPlugins.contains(where: { $0.id == Self.pluginId }),
                  !overview.availablePlugins.contains(where: { $0.id == Self.pluginId }),
                  !overview.marketplaces.contains(where: { $0.id == Self.marketplaceId })
            else { throw CheckFailure("plugin ou source encore présent") }
        }
    }

    /// Option sensible écrite mais jamais relue, puis effacée par `clearOptionKeys` ; contrôle sur la réponse brute de
    /// l'hôte (`PluginInfo` retire lui-même les clés sensibles de `configuredOptions`).
    private func exerciseConfiguration(_ plugins: PluginManagementClient, client: ChannelClient, _ report: inout CheckReport) async {
        guard await runStep("configuration : label et codeFactice (portée Utilisateur)", &report, { () async throws -> Void in
            let diagnostics = try await plugins.configure(
                pluginId: Self.pluginId,
                options: ["label": .string("essai"), "codeFactice": .string(Self.fakeSensitiveValue)],
                clearing: [], scope: .user)
            if let error = diagnostics.first(where: \.isError) { throw CheckFailure(error.message) }
        }) != nil else { return }
        await runStep("configuration : codeFactice absent de configuredOptions", &report) {
            let options = try await configuredOptions(client)
            await emit("plugins.listPlugins.configured", options.record)
            guard options.keys == ["label"], options.label == "essai" else { throw CheckFailure("configuredOptions : \(options.keys)") }
            guard options.sources["codeFactice"] != nil else { throw CheckFailure("optionSources sans codeFactice") }
        }
        await runStep("configuration : effacement de codeFactice (clearOptionKeys)", &report) {
            let diagnostics = try await plugins.configure(pluginId: Self.pluginId, options: [:], clearing: ["codeFactice"],
                                                          scope: .user)
            if let error = diagnostics.first(where: \.isError) { throw CheckFailure(error.message) }
            let options = try await configuredOptions(client)
            await emit("plugins.listPlugins.cleared", options.record)
            guard options.sources["codeFactice"] == nil else { throw CheckFailure("codeFactice toujours défini") }
            guard options.label == "essai" else { throw CheckFailure("label perdu") }
        }
    }

    /// Options du plugin jetable telles que l'hôte les renvoie : clés de `configuredOptions`, valeur de `label` et
    /// `optionSources`. Les autres valeurs ne sont pas gardées.
    private struct ConfiguredOptions {
        var keys: [String]
        var label: String?
        var sources: [String: String]

        var record: JSONValue {
            .object([
                "configuredKeys": .array(keys.map(JSONValue.string)),
                "optionSources": .object(sources.mapValues(JSONValue.string)),
            ])
        }
    }

    private func configuredOptions(_ client: ChannelClient) async throws -> ConfiguredOptions {
        let params: [String: JSONValue] = ["workspacePath": .string(workspace), "configScope": .string("user")]
        let value = try await client.call(PluginManagementClient.channel, "listPlugins", .array([RPCValue(.object(params))]))
            .jsonValue ?? .null
        guard let entry = value["plugins"]?.arrayValue?.first(where: { $0["id"]?.stringValue == Self.pluginId }) else {
            throw CheckFailure("\(Self.pluginId) absent de listPlugins")
        }
        let configured = entry["configuredOptions"]?.objectValue ?? [:]
        return ConfiguredOptions(
            keys: configured.keys.sorted(), label: configured["label"]?.stringValue,
            sources: (entry["optionSources"]?.objectValue ?? [:]).compactMapValues(\.stringValue))
    }

    private func installed(_ plugins: PluginManagementClient, scope: ExtensionScope) async throws -> InstalledPlugin {
        guard let plugin = try await plugins.overview(scope: scope).installedPlugins.first(where: { $0.id == Self.pluginId }) else {
            throw CheckFailure("\(Self.pluginId) absent des installés (\(scope.wireName))")
        }
        return plugin
    }

    // MARK: - Ménage

    /// Toujours exécuté : session, modèle d'Explore, sous-agents jetables, plugin et source.
    private func cleanUp(_ agents: SubagentsClient, _ plugins: PluginManagementClient, client: ChannelClient,
                         _ report: inout CheckReport, _ resources: Resources) async {
        var resources = resources
        if resources.sessionId != nil {
            await deleteSession(AgentV4(client: client, workspacePath: workspace), &report, &resources)
        }
        if let pending = resources.exploreRestore {
            _ = await restoreExplore(agents, pending.agent, pending.selection, &report)
        }
        await runStep("nettoyage final", &report) { () async throws -> Void in
            let removed = try await removeLeftovers(agents, plugins)
            print("  → \(removed.isEmpty ? "aucun reste" : "retiré : " + removed.joined(separator: ", "))")
        }
    }

    /// Supprime sous-agents jetables (fichiers du projet de la sonde seulement, chemins lus dans la liste), plugin et
    /// source jetables s'ils existent ; rend ce qui a été retiré.
    private func removeLeftovers(_ agents: SubagentsClient, _ plugins: PluginManagementClient) async throws -> [String] {
        var removed: [String] = []
        for agent in try await agents.list(scope: scope).agents
        where Self.isDisposable(agent.name) && agent.isEditable && agent.scope == .workspace
            && agent.path.hasPrefix(workspace + "/") {
            try await agents.delete(agent)
            removed.append(agent.name)
        }
        let overview = try await plugins.overview(scope: .user)
        if overview.installedPlugins.contains(where: { $0.id == Self.pluginId }) {
            if let error = try await plugins.uninstall(pluginId: Self.pluginId, scope: .user).first(where: \.isError) {
                throw CheckFailure(error.message)
            }
            removed.append(Self.pluginId)
        }
        if overview.marketplaces.contains(where: { $0.id == Self.marketplaceId }) {
            if let error = try await plugins.removeMarketplace(id: Self.marketplaceId, scope: .user).first(where: \.isError) {
                throw CheckFailure(error.message)
            }
            removed.append(Self.marketplaceId)
        }
        return removed
    }

    // MARK: - Outils

    private func listedAgent(_ agents: SubagentsClient, _ matches: (AgentSummary) -> Bool) async throws -> AgentSummary {
        guard let agent = try await agents.list(scope: scope).agents.first(where: matches) else {
            throw CheckFailure("absent de la liste du projet")
        }
        return agent
    }

    private func emit(_ name: String, _ value: JSONValue) async {
        await output.emit(kind: "state", step: 0, name: name, value: value)
    }

    private static func isDisposable(_ name: String) -> Bool { name == agentName || name == renamedAgentName }

    private static func agentConfig(name: String) -> SubAgentConfig {
        var config = SubAgentConfig(name: name, description: "Sous-agent jetable de zcode-probe",
                                    systemPrompt: "Réponds uniquement PONG.")
        config.color = .cyan
        config.tools = ["Read", "Grep"]
        config.injectAgentsMd = true
        return config
    }

    private static func operationId() -> String { UUID().uuidString.lowercased() }

    private static func json(_ selection: ModelSelection?) -> JSONValue {
        selection.flatMap { try? V4JSON.encode($0) } ?? .null
    }

    private static func describe(_ selection: ModelSelection?) -> String {
        guard let selection else { return "aucune surcharge" }
        return [selection.providerId, selection.modelId, selection.options?.reasoningLevel].compactMap(\.self).joined(separator: " · ")
    }

    /// Identifiants seulement : la liste porte aussi les invites des vrais agents de l'hôte.
    private static func summary(of list: AgentsListResult) -> JSONValue {
        .object([
            "agents": .array(list.agents.map { .string($0.id) }),
            "userAgents": .array(list.userAgents.map { .string($0.id) }),
            "pluginAgents": .array(list.pluginAgents.map { .string($0.id) }),
            "userScopeAvailable": .bool(list.userScopeAvailable),
        ])
    }

    private static func summary(of agent: AgentSummary) -> JSONValue {
        .object([
            "id": .string(agent.id), "path": .string(agent.path), "scope": .string(agent.scope.rawValue),
            "source": .string(agent.source.rawValue), "enabled": .bool(agent.enabled), "readOnly": .bool(agent.readOnly),
        ])
    }

    private static func summary(of overview: PluginsOverview) -> JSONValue {
        .object([
            "supported": .bool(overview.supported),
            "marketplaces": .array(overview.marketplaces.map { .string($0.id) }),
            "installedPlugins": .array(overview.installedPlugins.map {
                .object(["id": .string($0.id), "enabled": .bool($0.enabled)])
            }),
            "availablePlugins": .number(Double(overview.availablePlugins.count)),
        ])
    }

    private static func summary(of result: MarketplaceMutationResult) -> JSONValue {
        .object([
            "marketplace": result.marketplace.map { .string($0.id) } ?? .null,
            "marketplaces": .array(result.marketplaces.map { .string($0.id) }),
            "diagnostics": .array(result.diagnostics.map {
                .object(["code": .string($0.code), "severity": $0.severity.map(JSONValue.string) ?? .null])
            }),
        ])
    }

    private static func turnState(in snapshot: ConversationSnapshot, for commandId: String) -> TurnState? {
        guard case .turnHeader(let turn)? = turnHeader(in: snapshot, for: commandId)?.content else { return nil }
        return turn.state
    }

    /// Lignes du tour, pour diagnostiquer une invocation manquée : genre, nom de l'outil ou type de sous-agent.
    private static func turnRows(in snapshot: ConversationSnapshot, for commandId: String) -> [String] {
        guard let header = turnHeader(in: snapshot, for: commandId) else { return [] }
        return snapshot.rows.filter { $0.turnId == header.turnId && $0.rowId != header.rowId }.map { row in
            switch row.content {
            case .toolCall(let call): "toolCall \(call.toolName) (\(call.status.rawValue))"
            case .subagent(let value): "subagent \(value.subagentType)"
            default: row.kind.rawValue
            }
        }
    }
}
