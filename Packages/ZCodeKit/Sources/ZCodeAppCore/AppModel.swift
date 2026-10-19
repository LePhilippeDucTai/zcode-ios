import Foundation
import Observation
import ZCodeV4

/// Racine de l'app : hôtes, une connexion par hôte, une liste de sessions par projet.
@MainActor
@Observable
public final class AppModel {
    private struct SessionsKey: Hashable {
        let hostId: UUID
        let workspace: String
    }

    private struct ConversationKey: Hashable {
        let hostId: UUID
        let workspace: String
        let sessionId: String
    }

    /// Extensions d'un hôte pour une portée : jamais partagées entre deux hôtes, même avec des chemins identiques.
    private struct ExtensionsKey: Hashable {
        let hostId: UUID
        let scope: ExtensionScope
    }

    public let hostStore: HostStore
    public let builder: CommandBuilder
    /// Dates d'archivage des conversations (délai de suppression définitive), persistées sur cet iPhone.
    public let archiveStore: ArchiveStore
    /// Dernière activité vue de chaque session (pastille « non lu »), persistée sur cet iPhone.
    public let seenStore: SeenStore
    /// Sessions épinglées, persistées sur cet iPhone.
    public let pinStore: PinStore
    /// Prompts favoris, communs à tous les hôtes, persistés sur cet iPhone.
    public let promptStore: PromptStore
    /// Copies hors ligne des conversations et des listes de sessions (lecture sans connexion).
    public let offlineCache: ConversationCache
    private let dependencies: ConnectionDependencies
    /// Horloge (réglable dans les tests) pour dater ce qui est « vu ».
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var connections: [UUID: HostConnection] = [:]
    @ObservationIgnored private var sessionModels: [SessionsKey: SessionsModel] = [:]

    @ObservationIgnored private var conversations: [ConversationKey: ConversationModel] = [:]
    @ObservationIgnored private var catalogs: [UUID: ModelCatalog] = [:]
    @ObservationIgnored private var usages: [UUID: UsageModel] = [:]
    @ObservationIgnored private var changeModels: [SessionsKey: WorkspaceChangesModel] = [:]
    @ObservationIgnored private var browsers: [SessionsKey: FileBrowser] = [:]
    @ObservationIgnored private var subagentModels: [ExtensionsKey: SubagentsModel] = [:]
    @ObservationIgnored private var pluginModels: [ExtensionsKey: PluginsModel] = [:]
    @ObservationIgnored private var slashCatalogs: [SessionsKey: SlashCatalog] = [:]
    @ObservationIgnored private var savedWorkflowModels: [SessionsKey: SavedWorkflowsModel] = [:]

    public init(hostStore: HostStore, dependencies: ConnectionDependencies,
                archiveStore: ArchiveStore = ArchiveStore(), seenStore: SeenStore = SeenStore(),
                pinStore: PinStore = PinStore(), promptStore: PromptStore = PromptStore(),
                offlineCache: ConversationCache = ConversationCache(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        self.hostStore = hostStore
        self.dependencies = dependencies
        self.archiveStore = archiveStore
        self.seenStore = seenStore
        self.pinStore = pinStore
        self.promptStore = promptStore
        self.offlineCache = offlineCache
        builder = CommandBuilder(clientId: dependencies.clientId)
    }

    public func connection(for host: Host) -> HostConnection {
        if let existing = connections[host.id] { return existing }
        let connection = HostConnection(host: host, endpoint: hostStore.endpoint(for: host), dependencies: dependencies)
        connections[host.id] = connection
        return connection
    }

    public func sessions(for host: Host, workspace: String) -> SessionsModel {
        let key = SessionsKey(hostId: host.id, workspace: workspace)
        if let existing = sessionModels[key] { return existing }
        let model = SessionsModel(connection: connection(for: host), workspace: workspace,
                                  archiveStore: archiveStore, seenStore: seenStore, pinStore: pinStore,
                                  cache: offlineCache, now: now)
        sessionModels[key] = model
        return model
    }

    /// Sessions en cours de l'hôte, tous projets (lot 13J) : listes en cache, créées au besoin sans être démarrées.
    /// Tant que l'hôte n'est pas joint (non connecté, connexion en cours), seule une liste vivante compte : avant
    /// `server-info`, les projets connus (ajoutés à la main, souvent aucun) ne disent pas qu'il n'y a rien.
    public func activeSessions(for host: Host) -> ActiveSessionsState {
        let connection = connection(for: host)
        let sources = connection.workspaces.map { workspace in
            let model = sessions(for: host, workspace: workspace)
            let status = Self.activeStatus(of: model)
            return ActiveSessionsSource(workspace: workspace, status: status,
                                        sessions: status == .live ? model.visibleSessions : [])
        }
        let reaching = connection.state == .idle || connection.state == .connecting
        if reaching, !sources.contains(where: { $0.status == .live }) { return .loading }
        return ActiveSessions.state(from: sources)
    }

    /// Clé de la tâche de la fiche qui appelle `watchActiveSessions(for:)`.
    public func activeSessionsWatchKey(for host: Host) -> ActiveSessionsWatchKey {
        let connection = connection(for: host)
        return ActiveSessionsWatchKey(workspaces: connection.workspaces, connected: connection.state == .connected)
    }

    /// Démarre la liste de chaque projet de l'hôte (mêmes modèles que la liste d'un projet).
    public func watchActiveSessions(for host: Host) async {
        let models = connection(for: host).workspaces.map { sessions(for: host, workspace: $0) }
        // Tâches non structurées sur l'acteur principal (un groupe de tâches bute sur l'isolation des modèles).
        let tasks = models.map { model in Task { await model.startIfNeeded() } }
        for task in tasks { await task.value }
    }

    /// Relit la liste de chaque projet de l'hôte (tirer pour actualiser la fiche).
    public func refreshActiveSessions(for host: Host) async {
        let models = connection(for: host).workspaces.map { sessions(for: host, workspace: $0) }
        // Tâches non structurées sur l'acteur principal (un groupe de tâches bute sur l'isolation des modèles).
        let tasks = models.map { model in Task { await model.refresh() } }
        for task in tasks { await task.value }
    }

    private static func activeStatus(of model: SessionsModel) -> ActiveSessionsSource.Status {
        // Copie hors ligne : état figé, qui ne compte pas ; pendant le premier abonnement, la recherche continue.
        if model.isLocked { return model.phase == .loading ? .loading : .unavailable }
        if model.index != nil { return .live }             // une relecture en cours garde la liste
        switch model.phase {
        case .idle, .loading: return .loading
        case .failed: return .unavailable
        case .ready: return .live
        }
    }

    public func conversation(for host: Host, workspace: String, sessionId: String,
                             readOnly: Bool = false) -> ConversationModel {
        let key = ConversationKey(hostId: host.id, workspace: workspace, sessionId: sessionId)
        if let existing = conversations[key] { return existing }
        let model = ConversationModel(connection: connection(for: host), builder: builder,
                                      workspace: workspace, sessionId: sessionId,
                                      catalog: readOnly ? nil : modelCatalog(for: host), readOnly: readOnly,
                                      // Un fil de sous-agent n'a pas de copie propre.
                                      cache: readOnly ? nil : offlineCache,
                                      cacheKey: readOnly ? nil : SessionKey(hostId: host.id, workspace: workspace,
                                                                            sessionId: sessionId),
                                      now: now)
        conversations[key] = model
        return model
    }

    /// Conversation affichée : jamais en pastille, vue jusqu'à sa dernière activité connue.
    public func conversationDidAppear(host: Host, workspace: String, sessionId: String) {
        let key = SessionKey(hostId: host.id, workspace: workspace, sessionId: sessionId)
        seenStore.didOpen(key)
        if let last = lastActivity(hostId: host.id, workspace: workspace, sessionId: sessionId) {
            seenStore.markSeen(key, at: last)
        }
    }

    /// Conversation quittée : vue jusqu'à maintenant (ou jusqu'à l'activité publiée si l'index est en avance) ; ce que
    /// l'agent fait ensuite redevient « non lu ».
    public func conversationDidDisappear(host: Host, workspace: String, sessionId: String) {
        let key = SessionKey(hostId: host.id, workspace: workspace, sessionId: sessionId)
        let nowMs = now().timeIntervalSince1970 * 1000
        seenStore.didClose(key, at: max(lastActivity(hostId: host.id, workspace: workspace, sessionId: sessionId) ?? 0, nowMs))
    }

    /// Passage en arrière-plan : iOS peut tuer l'app sans appeler `onDisappear`, donc les conversations affichées sont
    /// déjà vues jusqu'à maintenant (elles restent ouvertes).
    public func sceneDidEnterBackground() {
        let nowMs = now().timeIntervalSince1970 * 1000
        for key in seenStore.openSessions {
            let last = lastActivity(hostId: key.hostId, workspace: key.workspace, sessionId: key.sessionId) ?? 0
            seenStore.markSeen(key, at: max(last, nowMs))
        }
    }

    /// Date de création d'une session (ms), lue dans l'index déjà chargé du projet ; `nil` si l'index ne la connaît pas
    /// (le snapshot de conversation ne la porte pas). Ne crée pas de `SessionsModel`.
    public func sessionCreatedAt(host: Host, workspace: String, sessionId: String) -> Double? {
        sessionModels[SessionsKey(hostId: host.id, workspace: workspace)]?.index?.session(id: sessionId)?.createdAt
    }

    private func lastActivity(hostId: UUID, workspace: String, sessionId: String) -> Double? {
        sessionModels[SessionsKey(hostId: hostId, workspace: workspace)]?.index?.session(id: sessionId)?.lastActivityAt
    }

    public func deleteSession(host: Host, workspace: String, sessionId: String) async throws {
        try await sessions(for: host, workspace: workspace).deleteSession(sessionId, builder: builder)
        await forgetConversation(hostId: host.id, workspace: workspace, sessionId: sessionId)
        await offlineCache.remove(SessionKey(hostId: host.id, workspace: workspace, sessionId: sessionId))
    }

    public func renameSession(host: Host, workspace: String, sessionId: String, title: String) async throws {
        try await sessions(for: host, workspace: workspace).renameSession(sessionId, title: title, builder: builder)
    }

    /// Action « Supprimer » de l'app : la conversation est archivée sur l'hôte (supprimée définitivement au bout de
    /// 30 jours), pas effacée.
    public func archiveSession(host: Host, workspace: String, sessionId: String) async throws {
        try await sessions(for: host, workspace: workspace).archive(sessionId, builder: builder)
        await forgetConversation(hostId: host.id, workspace: workspace, sessionId: sessionId)
        await offlineCache.remove(SessionKey(hostId: host.id, workspace: workspace, sessionId: sessionId))
    }

    private func forgetConversation(hostId: UUID, workspace: String, sessionId: String) async {
        let key = ConversationKey(hostId: hostId, workspace: workspace, sessionId: sessionId)
        // Arrêt avant le retrait : `stop()` change `phase` et fait réévaluer l'écran ouvert, qui redemande la
        // conversation ; retirée plus tôt, elle serait recréée (inactive) dans le cache.
        // La copie est détachée d'abord : ce `stop()` (et un autre, tardif, quand l'écran se ferme) ne doit pas la réécrire.
        conversations[key]?.detachOfflineCache()
        await conversations[key]?.stop()
        conversations[key] = nil
    }

    public func modelCatalog(for host: Host) -> ModelCatalog {
        if let existing = catalogs[host.id] { return existing }
        let catalog = ModelCatalog(connection: connection(for: host))
        catalogs[host.id] = catalog
        return catalog
    }

    /// Utilisation du Coding Plan d'un hôte (une instance par hôte, relue à la demande).
    public func usage(for host: Host) -> UsageModel {
        if let existing = usages[host.id] { return existing }
        let usage = UsageModel(connection: connection(for: host), catalog: modelCatalog(for: host))
        usages[host.id] = usage
        return usage
    }

    /// Sous-agents d'un hôte pour une portée (une instance par hôte et portée, relue à la demande).
    public func subagents(for host: Host, scope: ExtensionScope) -> SubagentsModel {
        let key = ExtensionsKey(hostId: host.id, scope: scope)
        if let existing = subagentModels[key] { return existing }
        let model = SubagentsModel(connection: connection(for: host), scope: scope)
        subagentModels[key] = model
        return model
    }

    /// Plugins d'un hôte pour une portée (une instance par hôte et portée, relue à la demande).
    public func plugins(for host: Host, scope: ExtensionScope) -> PluginsModel {
        let key = ExtensionsKey(hostId: host.id, scope: scope)
        if let existing = pluginModels[key] { return existing }
        let model = PluginsModel(connection: connection(for: host), scope: scope)
        pluginModels[key] = model
        return model
    }

    /// Catalogue du panneau « / » d'un projet (une instance par hôte et projet, relue à la demande).
    public func slashCatalog(for host: Host, workspace: String) -> SlashCatalog {
        let key = SessionsKey(hostId: host.id, workspace: workspace)
        if let existing = slashCatalogs[key] { return existing }
        let catalog = SlashCatalog(connection: connection(for: host), workspace: workspace,
                                   subagents: subagents(for: host, scope: .workspace(workspace)))
        slashCatalogs[key] = catalog
        return catalog
    }

    /// Workflows enregistrés d'un projet (une instance par hôte et projet).
    public func savedWorkflows(for host: Host, workspace: String) -> SavedWorkflowsModel {
        let key = SessionsKey(hostId: host.id, workspace: workspace)
        if let existing = savedWorkflowModels[key] { return existing }
        let model = SavedWorkflowsModel(connection: connection(for: host), workspace: workspace,
                                        sessions: sessions(for: host, workspace: workspace), builder: builder)
        savedWorkflowModels[key] = model
        return model
    }

    /// Modifications Git d'un projet (une instance par projet, comme la liste des sessions).
    public func workspaceChanges(for host: Host, workspace: String) -> WorkspaceChangesModel {
        let key = SessionsKey(hostId: host.id, workspace: workspace)
        if let existing = changeModels[key] { return existing }
        let model = WorkspaceChangesModel(connection: connection(for: host), workspace: workspace)
        changeModels[key] = model
        return model
    }

    /// Fichiers d'un projet (dossiers lus gardés le temps de la session de l'app).
    public func fileBrowser(for host: Host, workspace: String) -> FileBrowser {
        let key = SessionsKey(hostId: host.id, workspace: workspace)
        if let existing = browsers[key] { return existing }
        let browser = FileBrowser(connection: connection(for: host), root: workspace)
        browsers[key] = browser
        return browser
    }

    /// Après l'ajout ou le retrait d'un projet manuel.
    public func refreshHost(_ id: UUID) {
        if let host = hostStore.host(id: id) {
            connections[id]?.host = host
        }
    }

    /// Mode des nouvelles sessions d'un hôte ; la connexion reprend l'hôte modifié (`SessionsModel` le lit à la création).
    public func setDefaultMode(_ mode: String?, for host: Host) {
        hostStore.setDefaultMode(mode, for: host.id)
        refreshHost(host.id)
    }

    /// Adresse ou token modifiés : connexion et listes repartent de zéro.
    public func hostDidChange(_ id: UUID) async {
        await hostDidChange(id, removing: false)
    }

    /// `removing` : hôte supprimé, ses copies hors ligne ne doivent plus être réécrites par un `stop()`.
    private func hostDidChange(_ id: UUID, removing: Bool) async {
        for (key, model) in conversations where key.hostId == id {
            if removing { model.detachOfflineCache() }
            await model.stop()
            conversations[key] = nil
        }
        for (key, model) in sessionModels where key.hostId == id {
            if removing { model.detachOfflineCache() }
            await model.stop()
            sessionModels[key] = nil
        }
        changeModels = changeModels.filter { $0.key.hostId != id }
        browsers = browsers.filter { $0.key.hostId != id }
        subagentModels = subagentModels.filter { $0.key.hostId != id }
        pluginModels = pluginModels.filter { $0.key.hostId != id }
        slashCatalogs = slashCatalogs.filter { $0.key.hostId != id }
        savedWorkflowModels = savedWorkflowModels.filter { $0.key.hostId != id }
        usages.removeValue(forKey: id)
        catalogs.removeValue(forKey: id)?.stop()
        if let connection = connections.removeValue(forKey: id) {
            await connection.disconnect()
        }
    }

    public func removeHost(_ id: UUID) async {
        await hostDidChange(id, removing: true)
        await offlineCache.removeAll(hostId: id)
        hostStore.remove(id)
    }

    /// Passage en arrière-plan : iOS peut tuer l'app sans arrêter les écrans, donc les conversations et les listes
    /// en mémoire sont écrites maintenant.
    public func saveOfflineCopies() async {
        for model in conversations.values { await model.saveOfflineCopy() }
        for model in sessionModels.values { await model.saveOfflineCopy() }
    }

    /// Octets des copies hors ligne d'un hôte.
    public func offlineCacheBytes(for host: Host) async -> Int {
        await offlineCache.bytes(hostId: host.id)
    }

    /// Vide les copies de l'hôte sur le disque ; les modèles encore en mémoire gardent leur état (un `stop()` ou le
    /// prochain passage en arrière-plan le réécrit).
    public func clearOfflineCache(for host: Host) async {
        await offlineCache.removeAll(hostId: host.id)
    }

    /// Retour au premier plan : les sockets ont pu mourir pendant la veille de l'iPhone ou du Mac.
    public func sceneDidBecomeActive() async {
        for (key, model) in sessionModels {
            guard let connection = connections[key.hostId] else { continue }
            if case .failed = model.phase {
                await model.refresh()
            } else if model.phase == .ready, !(await connection.isAlive()) {
                await model.refresh()
            }
        }
        // Seules les conversations dont l'écran est ouvert sont abonnées (les autres sont en `idle`).
        for (key, model) in conversations {
            guard let connection = connections[key.hostId] else { continue }
            if case .failed = model.phase {
                await model.refresh()
            } else if model.phase == .ready, !(await connection.isAlive()) {
                await model.refresh()
            }
        }
        for catalog in catalogs.values {
            await catalog.startIfNeeded()                    // l'écoute `onDidChange` meurt avec la connexion
        }
        // Quotas déjà lus (ou en échec) : relus s'ils datent de plus d'une minute — le rappel du composeur doit rester
        // juste après une veille. Un quota jamais ouvert n'est pas lu pour autant.
        for usage in usages.values where usage.phase != .idle {
            await usage.loadIfNeeded(maxAge: 60)
        }
        for connection in connections.values where connection.state == .connected {
            if !(await connection.isAlive()) {
                _ = await connection.ensureConnected()
            }
        }
    }

    /// Interface web officielle de l'hôte (secours) ; `nil` sans token.
    public func webInterfaceURL(for host: Host) -> URL? {
        hostStore.endpoint(for: host)?.webUIURL
    }
}
