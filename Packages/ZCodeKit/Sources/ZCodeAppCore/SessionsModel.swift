import Foundation
import Observation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

public enum SessionsError: LocalizedError, Equatable {
    case notConnected(String)
    case rejected(String)
    case deleteRejected(String)
    case archiveRejected(String)
    case renameRejected(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let reason): reason
        case .rejected(let reason): "Création refusée par l'hôte (\(reason))."
        case .deleteRejected(let reason): "Suppression refusée par l'hôte (\(reason))."
        case .archiveRejected(let reason): "Archivage refusé par l'hôte (\(reason))."
        case .renameRejected(let reason): "Renommage refusé par l'hôte (\(reason))."
        }
    }
}

/// Conversation archivée, pour l'écran « Archivées ».
public struct ArchivedSession: Identifiable, Equatable, Sendable {
    public let sessionId: String
    public let title: String
    /// Dernière activité connue de l'hôte.
    public let updatedAt: Date?
    /// Date d'archivage tenue par l'app (délai de suppression) ; la première vue sert pour une archivée ailleurs.
    public let archivedAt: Date?

    public var id: String { sessionId }
}

/// Sessions d'un projet, tenues à jour par l'index du serveur.
@MainActor
@Observable
public final class SessionsModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Reprises automatiques après une perte de connexion avant de laisser la main (bouton « Réessayer »).
    public static let maxAutomaticRestarts = 3

    /// Délai avant suppression définitive d'une conversation archivée.
    public static let archiveRetention: TimeInterval = 30 * 24 * 3600

    public let workspace: String
    public private(set) var phase: Phase = .idle
    public private(set) var index: SessionsIndex?
    /// Sessions créées ici que le serveur ne publiera qu'à leur premier message.
    public private(set) var localDrafts: [String] = []
    /// Sessions cachées de la liste : archivées ou supprimées définitivement (l'index du serveur les liste encore,
    /// c'est l'index des tâches de l'hôte qui tient ces états, comme dans les interfaces officielles).
    public private(set) var hiddenIds: Set<String> = []
    /// Archivages en cours : cachés dès le geste (pas de confirmation), remis dans la liste si l'hôte refuse.
    private var archivingIds: Set<String> = []
    /// Conversations archivées, pour l'écran « Archivées ».
    public private(set) var archived: [ArchivedSession] = []
    public private(set) var archivedPhase: Phase = .idle
    /// Lecture hors ligne (lot 13E) : date de la copie affichée (copie du cache, ou dernier état vivant figé quand
    /// l'hôte devient injoignable) ; `nil` dès qu'un état vivant arrive.
    public private(set) var offlineCopyDate: Date?
    /// Aucune action vers l'hôte : la liste affichée est une copie hors ligne.
    public var isLocked: Bool { offlineCopyDate != nil }
    private let connection: HostConnection
    private let archiveStore: ArchiveStore
    private let seenStore: SeenStore
    private let pinStore: PinStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var feed: TopicFeed<SessionsIndex>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var restarts = 0
    /// Incrémentée à chaque `start()`/`stop()` : un démarrage dépassé n'installe rien et ses événements sont ignorés.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cache: ConversationCache?
    /// Date du dernier état vivant reçu : celle de la copie figée si l'hôte devient injoignable.
    @ObservationIgnored private var lastLiveAt: Date?
    /// Copie effacée par l'app (hôte supprimé ou modifié) : plus rien n'est écrit dans le cache.
    @ObservationIgnored private var cacheDetached = false

    public init(connection: HostConnection, workspace: String,
                archiveStore: ArchiveStore = ArchiveStore(), seenStore: SeenStore = SeenStore(),
                pinStore: PinStore = PinStore(), cache: ConversationCache? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.connection = connection
        self.workspace = workspace
        self.archiveStore = archiveStore
        self.seenStore = seenStore
        self.pinStore = pinStore
        self.cache = cache
        self.now = now
    }

    public var sessions: [SessionSummary] { index?.byRecentActivity ?? [] }

    /// La liste affichée : sessions publiées, moins celles archivées ou supprimées définitivement.
    public var visibleSessions: [SessionSummary] {
        sessions.filter { !hiddenIds.contains($0.sessionId) && !archivingIds.contains($0.sessionId) }
    }

    /// Sessions créées ici et pas encore publiées (sans doublon une fois publiées).
    public var drafts: [String] { localDrafts.filter { index?.session(id: $0) == nil } }

    /// Clé locale d'une session de ce projet (vu, épingle).
    public func key(_ sessionId: String) -> SessionKey {
        SessionKey(hostId: connection.host.id, workspace: workspace, sessionId: sessionId)
    }

    /// Activité sur l'hôte depuis la dernière consultation sur cet iPhone (pastille de la liste).
    public func isUnread(_ summary: SessionSummary) -> Bool {
        seenStore.isUnread(key(summary.sessionId), lastActivityAt: summary.lastActivityAt)
    }

    /// Sections de la liste pour la recherche `query` (vide : tout).
    public func layout(query: String) -> SessionListLayout {
        SessionListLayout(sessions: visibleSessions, drafts: drafts,
                          pinnedIds: pinStore.pinnedIds(hostId: connection.host.id, workspace: workspace), query: query)
    }

    public func isPinned(_ sessionId: String) -> Bool {
        pinStore.isPinned(key(sessionId))
    }

    public func togglePin(_ sessionId: String) {
        pinStore.setPinned(!isPinned(sessionId), key(sessionId))
    }

    public func startIfNeeded() async {
        switch phase {
        case .idle, .failed: await start()
        case .loading, .ready: break
        }
    }

    public func start() async {
        generation += 1
        let generation = self.generation
        await stopFeed()
        guard generation == self.generation else { return }
        phase = .loading
        // Rien d'affiché : la copie hors ligne, s'il y en a une, en attendant l'état vivant (ou à sa place).
        if index == nil, let cache, let copy = await cache.sessions(hostId: connection.host.id, workspace: workspace) {
            guard generation == self.generation else { return }
            if index == nil { showCopy(copy) }
        }
        let agent = await connection.agent(workspace: workspace)
        guard generation == self.generation else { return }
        guard let agent else {
            phase = .failed(connection.failure?.message ?? "Hôte injoignable.")
            goOfflineIfPossible(retryable: connection.failure?.isRetryable ?? true)
            return
        }
        let feed = TopicFeed<SessionsIndex>(topic: Topic.sessionsIndex(workspace), operations: agent.sessionsIndexOperations())
        self.feed = feed
        consumer = Task { [weak self] in
            for await event in feed.events {
                self?.handle(event, generation: generation)
            }
        }
        do {
            try await feed.start(frames: agent.sessionsIndexFrames())
        } catch {
            guard generation == self.generation else { return }
            phase = .failed(ConnectionFailure(error).message)
            goOfflineIfPossible(retryable: ConnectionFailure(error).isRetryable)
            return
        }
        guard generation == self.generation else { return }
        // Jointure d'archivage puis purge : silencieuses — la liste reste utilisable sans l'index des tâches.
        await refreshArchiveState()
        await purgeExpiredArchives()
    }

    /// Relance manuelle (tirer pour actualiser, « Réessayer », retour au premier plan).
    public func refresh() async {
        restarts = 0
        await start()
    }

    public func stop() async {
        generation += 1
        let generation = self.generation
        await saveOfflineCopy()
        guard generation == self.generation else { return }  // relancée pendant l'écriture : `start` ferme l'ancien flux
        await stopFeed()
    }

    /// Écrit la liste vivante affichée dans le cache hors ligne ; jamais une copie (elle y est déjà, avec sa date).
    public func saveOfflineCopy() async {
        guard offlineCopyDate == nil, let index else { return }
        // Liste vivante et à jour : datée de maintenant ; sinon du dernier index reçu.
        await write(index, savedAt: phase == .ready ? now() : (lastLiveAt ?? now()))
    }

    /// À appeler avant `stop()` quand l'app efface la copie de cet hôte : un `stop()` tardif ne la réécrit pas.
    public func detachOfflineCache() {
        cacheDetached = true
    }

    private func write(_ index: SessionsIndex, savedAt: Date) async {
        guard !cacheDetached, let cache else { return }
        await cache.saveSessions(index, hidden: hiddenIds.union(archivingIds), hostId: connection.host.id,
                                 workspace: workspace, savedAt: savedAt)
    }

    /// Affiche une copie hors ligne comme un index reçu, sans toucher aux états locaux (vu, épingles) : une copie
    /// ne fait pas autorité sur eux.
    private func showCopy(_ copy: OfflineCopy<SessionsIndex>) {
        index = copy.value
        offlineCopyDate = copy.savedAt
    }

    /// Hôte injoignable (panne réseau, pas un refus) : la liste vivante affichée devient une copie hors ligne, datée
    /// du dernier index reçu, et elle est écrite aussitôt dans le cache (une copie déjà chargée n'est jamais réécrite).
    private func goOfflineIfPossible(retryable: Bool) {
        guard retryable, offlineCopyDate == nil, let index else { return }
        let savedAt = lastLiveAt ?? now()
        offlineCopyDate = savedAt
        Task { await self.write(index, savedAt: savedAt) }
    }

    private func stopFeed() async {
        consumer?.cancel()
        consumer = nil
        let previous = feed
        feed = nil
        await previous?.stop()
    }

    /// Crée une session vide et la rend visible tout de suite.
    public func createSession(builder: CommandBuilder) async throws -> String {
        guard let agent = await connection.agent(workspace: workspace) else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        let request = connection.host.defaultMode.map(ModeOption.sessionRequest(for:))
        let ack = try await agent.send(builder.createSession(workspaceId: workspace, mode: request?.mode,
                                                             planEnabled: request?.planEnabled))
        guard ack.isAccepted, let sessionId = ack.result?.sessionId else {
            throw SessionsError.rejected(ack.reasonCode ?? ack.status.rawValue)
        }
        localDrafts.insert(sessionId, at: 0)
        return sessionId
    }

    /// Supprime la session sur l'hôte ; l'index publiera `session.removed`.
    public func deleteSession(_ sessionId: String, builder: CommandBuilder) async throws {
        guard let agent = await connection.agent(workspace: workspace) else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        let ack = try await agent.send(builder.deleteSession(sessionId: sessionId))
        guard ack.isAccepted else { throw SessionsError.deleteRejected(ack.reasonCode ?? ack.status.rawValue) }
        localDrafts.removeAll { $0 == sessionId }
    }

    /// Retire le brouillon local d'une session déjà perdue ou supprimée (la suppression sur l'hôte a pu être refusée).
    public func discardDraft(_ sessionId: String) {
        localDrafts.removeAll { $0 == sessionId }
    }

    /// Renomme la session sur l'hôte (`renameSession`, sans CAS) ; le nouveau titre revient par l'index et le snapshot.
    public func renameSession(_ sessionId: String, title: String, builder: CommandBuilder) async throws {
        guard let agent = await connection.agent(workspace: workspace) else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        let ack = try await agent.send(builder.renameSession(sessionId: sessionId, title: title))
        guard ack.isAccepted || ack.status == .noop else {
            throw SessionsError.renameRejected(ack.reasonCode ?? ack.status.rawValue)
        }
    }

    /// Archive la conversation : elle disparaît de la liste (ici et dans les interfaces officielles) et est supprimée
    /// définitivement au bout de 30 jours. Une session publiée est d'abord fermée sur l'hôte si elle y est chargée —
    /// un refus « introuvable » n'est pas une erreur (elle n'y occupe alors aucune place).
    public func archive(_ sessionId: String, builder: CommandBuilder) async throws {
        archivingIds.insert(sessionId)
        defer { archivingIds.remove(sessionId) }
        guard let channel = await connection.ensureConnected() else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        if localDrafts.contains(sessionId) || index?.session(id: sessionId) == nil {
            // Jamais publiée (aucun message) : il n'y a rien à archiver, la fermeture suffit. « Introuvable » n'est
            // pas une erreur non plus (brouillon perdu au redémarrage de l'hôte : elle n'existe plus nulle part).
            do {
                try await deleteSession(sessionId, builder: builder)
            } catch SessionsError.deleteRejected(let reason) where reason.contains("sessionNotFound") {}
            return
        }
        do {
            try await deleteSession(sessionId, builder: builder)
        } catch SessionsError.deleteRejected(let reason) where reason.contains("sessionNotFound") {
            // Pas chargée sur l'hôte : rien à fermer, l'archivage suffit.
        }
        do {
            try await TaskArchiveClient(client: channel, workspacePath: workspace).archive(taskId: sessionId)
        } catch {
            throw SessionsError.archiveRejected(Self.archiveFailureMessage(error))
        }
        archiveStore.record(hostId: connection.host.id, workspace: workspace, sessionId: sessionId, at: now())
        await refreshArchiveState()
    }

    /// Remet une conversation archivée dans la liste.
    public func unarchive(_ sessionId: String) async throws {
        guard let channel = await connection.ensureConnected() else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        do {
            try await TaskArchiveClient(client: channel, workspacePath: workspace).unarchive(taskId: sessionId)
        } catch {
            throw SessionsError.archiveRejected(Self.archiveFailureMessage(error))
        }
        archiveStore.remove(hostId: connection.host.id, workspace: workspace, sessionId: sessionId)
        await refreshArchiveState()
    }

    /// Suppression définituelle immédiate (sans attendre les 30 jours). Le tombeau la cache de toutes les listes ;
    /// son contenu reste dans la base de l'hôte, qui n'a pas d'API d'effacement.
    public func deleteArchivedNow(_ sessionId: String) async throws {
        guard let channel = await connection.ensureConnected() else {
            throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
        }
        do {
            _ = try await TaskArchiveClient(client: channel, workspacePath: workspace).deleteArchived(taskId: sessionId)
        } catch {
            throw SessionsError.archiveRejected(Self.archiveFailureMessage(error))
        }
        archiveStore.remove(hostId: connection.host.id, workspace: workspace, sessionId: sessionId)
        await cache?.remove(key(sessionId))                      // sa copie hors ligne part avec elle
        await refreshArchiveState()
    }

    /// Relit l'état d'archivage de l'hôte (écran « Archivées » et tirer pour actualiser). Une panne de l'index des
    /// tâches laisse la liste des sessions telle quelle : seule `archivedPhase` passe en échec.
    public func refreshArchived() async {
        archivedPhase = .loading
        await refreshArchiveState()
    }

    /// Relit l'index des tâches de l'hôte : jointure négative (archivées ∪ supprimées) pour la liste, et état de
    /// l'écran « Archivées ». Une session archivée reste dans l'index des sessions du serveur.
    private func refreshArchiveState() async {
        guard let channel = await connection.ensureConnected() else {
            archivedPhase = .failed(connection.failure?.message ?? "Hôte injoignable.")
            return
        }
        let tasks = TaskArchiveClient(client: channel, workspacePath: workspace)
        do {
            let archivedTasks = try await tasks.listArchived()
            let deleted = try await tasks.listDeletedIds()
            hiddenIds = deleted.union(archivedTasks.map(\.taskId))
            pruneLocalState()
            let hostId = connection.host.id
            archived = archivedTasks.map { task -> ArchivedSession in
                if let local = archiveStore.archivedAt(hostId: hostId, workspace: workspace, sessionId: task.taskId) {
                    return ArchivedSession(sessionId: task.taskId, title: task.title, updatedAt: task.updatedAt, archivedAt: local)
                }
                // Première vue d'une conversation archivée ailleurs : « maintenant » devient la date du délai.
                let firstSeen = now()
                archiveStore.record(hostId: hostId, workspace: workspace, sessionId: task.taskId, at: firstSeen)
                return ArchivedSession(sessionId: task.taskId, title: task.title, updatedAt: task.updatedAt, archivedAt: firstSeen)
            }
            archivedPhase = .ready
        } catch {
            archivedPhase = .failed(Self.archiveFailureMessage(error))
        }
    }

    /// Supprime définitivement les conversations archivées depuis plus de `archiveRetention`. Une entrée dont la
    /// suppression échoue reste pour le prochain passage.
    private func purgeExpiredArchives() async {
        let cutoff = now().addingTimeInterval(-Self.archiveRetention)
        let expired = archiveStore.entries(hostId: connection.host.id, workspace: workspace)
            .filter { $0.archivedAt <= cutoff }
        guard !expired.isEmpty, let channel = await connection.ensureConnected() else { return }
        let tasks = TaskArchiveClient(client: channel, workspacePath: workspace)
        for entry in expired {
            // `false` : désarchivée entre-temps (elle revient dans la liste) ou déjà supprimée — l'entrée part pareil.
            _ = try? await tasks.deleteArchived(taskId: entry.sessionId)
            archiveStore.remove(hostId: entry.hostId, workspace: entry.workspace, sessionId: entry.sessionId)
            await cache?.remove(key(entry.sessionId))
        }
        await refreshArchiveState()
    }

    /// États locaux des sessions qui ne sont plus dans la liste (supprimées, archivées) : retirés.
    private func pruneLocalState() {
        guard let index else { return }
        let keeping = Set(index.sessions.map(\.sessionId)).subtracting(hiddenIds)
        seenStore.prune(hostId: connection.host.id, workspace: workspace, keeping: keeping)
        pinStore.prune(hostId: connection.host.id, workspace: workspace, keeping: keeping)
    }

    private static func archiveFailureMessage(_ error: any Error) -> String {
        if case RPCError.remote(let remote) = error {
            let text = remote.message
            if !text.isEmpty { return text }
        }
        return ConnectionFailure(error).message
    }

    private func handle(_ event: FeedEvent<SessionsIndex>, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .updated(let index):
            self.index = index
            if offlineCopyDate != nil { offlineCopyDate = nil }
            lastLiveAt = now()
            seenStore.establishBaseline(hostId: connection.host.id, workspace: workspace,
                                        lastActivities: index.sessions.map(\.lastActivityAt))
            pruneLocalState()
            // Publiée par le serveur : ce n'est plus un brouillon (et elle ne doit pas revenir si elle est supprimée).
            localDrafts.removeAll { index.session(id: $0) != nil }
            phase = .ready
            restarts = 0
        case .failed(let reason):
            phase = .failed(reason)
            if reason == TopicFeedFailure.connectionLost, restarts < Self.maxAutomaticRestarts {
                restarts += 1
                Task { if generation == self.generation { await self.start() } }
            } else if reason == TopicFeedFailure.connectionLost {
                goOfflineIfPossible(retryable: true)             // plus de relance automatique : la liste reste figée
            }
        }
    }
}
