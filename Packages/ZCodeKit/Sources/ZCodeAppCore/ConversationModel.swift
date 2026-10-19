import Foundation
import Observation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

/// Résultat d'un envoi, pour le composeur.
public enum SendOutcome: Equatable, Sendable {
    /// Accepté ; `delivery` dit ce que l'hôte en a fait (`startNow`, `queue`, `guide`).
    case sent(delivery: String?)
    /// Refusé ou non transmis : le texte doit revenir dans le composeur.
    case failed
    /// Une file en pause attend : demander de la vider ou de la garder, puis renvoyer avec `heldQueue`
    /// (`itemIds` = file vue par l'utilisateur).
    case needsQueueChoice(itemIds: [String])
    /// Connexion coupée ou réponse illisible pendant l'envoi : l'hôte est interrogé (à la reprise, ou tout de suite si
    /// la connexion vit) et le message renvoyé tel quel si besoin.
    case unconfirmed
}

/// Issue de « Chercher plus loin » (`ConversationModel.searchOlder`).
public enum OlderSearchOutcome: Equatable, Sendable {
    /// Correspondance trouvée dans l'historique chargé : la plus récente d'entre elles.
    case found(Int)
    /// Début de la conversation atteint sans correspondance.
    case exhausted
    /// `searchPagesPerGesture` pages lues sans correspondance ; il en reste.
    case limitReached
    /// Page illisible ou hôte injoignable.
    case failed
}

/// Une conversation tenue à jour par le serveur, et les commandes qu'on y envoie.
/// Fichiers modifiés par un tour, ou la raison de leur absence.
public enum TurnChangesLoad: Equatable, Sendable {
    case loaded(FileChanges)
    case failed(String)
}

@MainActor
@Observable
public final class ConversationModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public static let maxAutomaticRestarts = 3
    /// Taille d'une page d'historique (comme l'interface web) ; le snapshot n'apporte que les 60 dernières lignes.
    nonisolated public static let historyPageSize = 60
    /// Passages de rapprochement sans issue pour un même envoi (l'hôte répond par une erreur ou une réponse illisible,
    /// ne peut pas encore répondre — `queryUnavailable` —, ou son renvoi reste illisible) avant de l'abandonner.
    public static let maxReconcileFailures = 3

    public let workspace: String
    public let sessionId: String
    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: ConversationSnapshot?
    /// Cellules affichables (une par élément, plus un pied par tour terminé ou en cours), cartes d'outils consécutives
    /// repliées en groupes (lot 13I) : les `ungroupedEntries` regroupées.
    public private(set) var entries: [ChatEntry] = []
    /// Entrées à plat, sans groupes : recherche et repères.
    public private(set) var ungroupedEntries: [ChatEntry] = []
    /// Groupes dépliés (`ToolGroup.id`).
    public private(set) var expandedToolGroups: Set<Int> = []
    /// Temps de travail de la session (lot 13F), recalculé avec `entries` ; « ≥ » tant que l'historique est partiel.
    public private(set) var workTime = SessionWorkTime.empty
    /// Incrémenté à chaque mise à jour du contenu : l'écran s'en sert pour suivre le bas de la conversation.
    public private(set) var contentVersion = 0
    public private(set) var loadingOlder = false
    /// La dernière page d'historique n'a pas pu être ajoutée (erreur réseau ou page écartée) : l'écran propose « Réessayer ».
    public private(set) var olderRowsFailed = false
    public private(set) var sending = false
    /// Au plus 8 pièces jointes par message (`MAX_CHAT_ATTACHMENTS` du web) et 20 Mio chacune (`attachmentMaxBytes`).
    public static let maxAttachments = 8
    public static let maxAttachmentBytes = 20 * 1024 * 1024
    /// Texte envoyé avec des pièces jointes seules : l'hôte accepte `text: ""` avec des pièces jointes (résultat de
    /// `zcode-probe attach` sur l'hôte réel, tâche 6).
    public static let attachmentOnlyText = ""
    private static let tooManyAttachments = "8 pièces jointes au plus par message."
    /// Pièces jointes du prochain message, dans l'ordre du choix.
    public private(set) var attachments: [ComposerAttachment] = []
    /// Données gardées jusqu'au téléversement réussi (nouvel essai possible).
    @ObservationIgnored private var pendingUploadData: [UUID: Data] = [:]
    @ObservationIgnored private var uploads: [UUID: Task<Void, Never>] = [:]
    /// Dernière commande refusée ou non transmise, affichée jusqu'à la prochaine action.
    public private(set) var commandError: String?
    /// Avis après une commande acceptée (compression mise en file), affiché jusqu'à « OK » ou l'envoi suivant.
    public private(set) var commandNotice: String?
    /// Modèle, effort et mode du prochain message ; `nil` avant le premier snapshot.
    public private(set) var settings: ComposerSettings?
    public let catalog: ModelCatalog?
    /// Messages partis sans accusé (connexion coupée pendant l'envoi), vérifiés à la reprise.
    public private(set) var unconfirmedCount = 0
    /// Texte d'un message abandonné après coup (refusé au rapprochement) : le composeur le remet dans le brouillon.
    public private(set) var returnedDraft: String?
    /// Réponse à une demande de l'agent en cours d'envoi (boutons du dock désactivés).
    public private(set) var respondingInteractionId: String?
    /// Tours terminés avec succès pendant que l'écran est ouvert (déclencheur de la vibration de fin).
    public private(set) var finishedTurns = 0
    /// Demandes (autorisation, question) apparues pendant que l'écran est ouvert (déclencheur de la vibration d'alerte).
    public private(set) var newInteractionAlerts = 0
    /// Demandes répondues depuis cet appareil, masquées jusqu'à ce que l'état de l'hôte les retire.
    private var answeredInteractionIds: Set<String> = []
    /// Comptes à rebours déjà suspendus (ou en cours de suspension) : une commande par demande.
    @ObservationIgnored private var snoozedInteractionIds: Set<String> = []
    /// Génération dont un état a déjà été reçu : le premier état d'un nouvel abonnement fait autorité sur les demandes.
    @ObservationIgnored private var interactionsGeneration: Int?
    private let connection: HostConnection
    private let builder: CommandBuilder
    @ObservationIgnored private var feed: TopicFeed<ConversationSnapshot>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var restarts = 0
    /// Incrémentée à chaque `start()`/`stop()` : un démarrage dépassé n'installe rien et ses événements sont ignorés.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var unconfirmed: [CommandEnvelope] = []
    @ObservationIgnored private var reconciling = false
    /// Génération déjà rapprochée : à la reprise, une passe par abonnement et non une par trame (les passes sans issue
    /// suivantes viennent de `scheduleRetry`).
    @ObservationIgnored private var reconciledGeneration: Int?
    /// Passages sans issue par envoi en attente (voir `maxReconcileFailures`) ; effacé quand l'envoi est réglé.
    @ObservationIgnored private var attempts: [CommandKey: Int] = [:]
    /// Un envoi illisible est arrivé pendant un passage : celui-ci repart à sa fin.
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// « Repartir d'ici » en cours : un second appui n'envoie rien.
    @ObservationIgnored private var forking = false
    /// Délais avant de réinterroger l'hôte après un passage sans issue (connexion saine), selon le nombre d'essais déjà
    /// perdus par l'envoi le plus avancé : le dernier vaut pour les suivants. Ils croissent, car une bannière « en
    /// cours de vérification » ne doit pas durer indéfiniment sur une connexion vivante, mais l'hôte a besoin de temps.
    public static let defaultReconcileRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
    private let reconcileRetryDelays: [Duration]

    /// Fil d'un sous-agent (lot 13D) : ni composeur, ni catalogue, ni vibrations ; seul l'abonnement parle à l'hôte.
    public let readOnly: Bool

    /// Lecture hors ligne (lot 13E) : date de la copie affichée (copie du cache, ou dernier état vivant figé quand
    /// l'hôte devient injoignable) ; `nil` dès qu'un état vivant arrive.
    public private(set) var offlineCopyDate: Date?
    /// Aucune action vers l'hôte : fil de sous-agent ou copie hors ligne.
    public var isLocked: Bool { readOnly || offlineCopyDate != nil }
    @ObservationIgnored private let cache: ConversationCache?
    @ObservationIgnored private let cacheKey: SessionKey?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Date du dernier état vivant reçu : celle de la copie figée si l'hôte devient injoignable.
    @ObservationIgnored private var lastLiveAt: Date?
    /// Copie effacée par l'app (archivage, hôte modifié) : plus rien n'est écrit dans le cache.
    @ObservationIgnored private var cacheDetached = false

    public init(connection: HostConnection, builder: CommandBuilder, workspace: String, sessionId: String,
                catalog: ModelCatalog? = nil, readOnly: Bool = false,
                cache: ConversationCache? = nil, cacheKey: SessionKey? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                reconcileRetryDelays: [Duration] = ConversationModel.defaultReconcileRetryDelays) {
        self.readOnly = readOnly
        self.cache = cache
        self.cacheKey = cacheKey
        self.now = now
        self.reconcileRetryDelays = reconcileRetryDelays.isEmpty ? Self.defaultReconcileRetryDelays : reconcileRetryDelays
        self.catalog = catalog
        self.connection = connection
        self.builder = builder
        self.workspace = workspace
        self.sessionId = sessionId
    }

    public var title: String? {
        guard let title = snapshot?.meta?.title, !title.isEmpty else { return nil }
        return title
    }

    /// `startNow`, `enqueue`, `guide`, `choice` ou `reject` (`snapshot.inputRouting`).
    public var routing: String { snapshot?.inputRouting?.mode ?? "startNow" }

    public var canStop: Bool { snapshot?.control?.canStop == true }

    /// Sous-agents en cours de la session (puce « N sous-agents », lot 13D).
    public var runningSubagents: [RunningSubagent] { snapshot?.runningSubagents ?? [] }

    /// Autorité du catalogue des skills : la session dès qu'elle a un historique (catalogue figé à son premier tour),
    /// sinon le projet — comme un brouillon du web, qui n'a pas encore de session. Non nul seulement après un snapshot,
    /// donc après l'abonnement à la conversation : l'hôte répond `-32004 « Session is not active »` au catalogue d'une
    /// session lue avant (tâche 0, D2).
    public var skillsCatalogSessionId: String? {
        (snapshot?.totalCount ?? 0) > 0 ? sessionId : nil
    }

    /// Des lignes plus anciennes que la fenêtre chargée existent sur l'hôte.
    /// Faux pour une copie hors ligne : rien ne peut être chargé sans l'hôte.
    public var hasOlderRows: Bool {
        guard offlineCopyDate == nil, let snapshot else { return false }
        return Self.hasOlderRows(in: snapshot)
    }

    private static func hasOlderRows(in snapshot: ConversationSnapshot) -> Bool {
        guard let loaded = snapshot.rows.first?.rowId, let first = snapshot.firstRowId else { return false }
        return loaded > first
    }

    /// Niveaux d'effort du modèle choisi (catalogue de l'hôte, sinon ceux annoncés par la session).
    public var effortLevels: [String] {
        if let selection = settings?.selection,
           let model = catalog?.view?.model(providerId: selection.providerId, modelId: selection.modelId) {
            return model.reasoningLevels
        }
        return snapshot?.config?.thoughtLevels ?? []
    }

    public func selectModel(providerId: String, modelId: String) {
        guard let view = catalog?.view else { return }
        settings?.selectModel(providerId: providerId, modelId: modelId, in: view)
    }

    public func selectEffort(_ level: String) {
        settings?.selectEffort(level)
    }

    public func selectMode(_ id: String) {
        settings?.selectMode(id)
    }

    // MARK: - Abonnement

    public func startIfNeeded() async {
        switch phase {
        case .idle, .failed: await start()
        case .loading, .ready: break
        }
    }

    public func start() async {
        await begin(restartingCatalog: false)
    }

    /// `restartingCatalog` : la connexion a été perdue, l'écoute du catalogue est morte avec elle et doit être rouverte
    /// (une seule fois, par `loadCatalog`) ; sinon le catalogue n'est démarré que s'il ne tourne pas déjà.
    private func begin(restartingCatalog: Bool) async {
        generation += 1
        retryTask?.cancel()
        let generation = self.generation
        await stopFeed()
        guard generation == self.generation else { return }
        phase = .loading
        // Rien d'affiché : la copie hors ligne, s'il y en a une, en attendant l'état vivant (ou à sa place).
        if snapshot == nil, let cache, let cacheKey, let copy = await cache.conversation(cacheKey) {
            guard generation == self.generation else { return }
            if snapshot == nil { showCopy(copy) }
        }
        // Le catalogue ne conditionne pas l'abonnement (hôte injoignable : deux séries de reconnexion à la suite sinon).
        if !readOnly { Task { await self.loadCatalog(generation: generation, restart: restartingCatalog) } }
        olderRowsFailed = false
        let agent = await connection.agent(workspace: workspace)
        guard generation == self.generation else { return }
        guard let agent else {
            phase = .failed(connection.failure?.message ?? "Hôte injoignable.")
            goOfflineIfPossible(retryable: connection.failure?.isRetryable ?? true)
            return
        }
        let feed = TopicFeed<ConversationSnapshot>(
            topic: Topic.conversation(sessionId), operations: agent.conversationOperations(sessionId: sessionId))
        self.feed = feed
        consumer = Task { [weak self] in
            for await event in feed.events {
                self?.handle(event, generation: generation)
            }
        }
        do {
            try await feed.start(frames: agent.conversationFrames())
        } catch {
            guard generation == self.generation else { return }
            phase = .failed(ConnectionFailure(error).message)
            goOfflineIfPossible(retryable: ConnectionFailure(error).isRetryable)
            await stopFeed()                                     // flux et consommateur ne servent plus à rien
        }
    }

    private func loadCatalog(generation: Int, restart: Bool) async {
        if restart { await catalog?.start() } else { await catalog?.startIfNeeded() }
        // Arrivé après le premier snapshot : une session sans modèle prend le défaut de l'hôte.
        guard generation == self.generation, let view = catalog?.view else { return }
        settings?.adoptDefaultSelection(from: view)
    }

    /// Relance manuelle (« Réessayer », retour au premier plan).
    public func refresh() async {
        restarts = 0
        await start()
    }

    /// Écran quitté : l'abonnement (qui reçoit le trafic de tout l'espace de travail) est fermé ; le dernier état
    /// reste affiché au retour, le temps que le nouvel abonnement apporte le snapshot.
    public func stop() async {
        generation += 1
        retryTask?.cancel()
        let generation = self.generation
        let savedAt = offlineSaveDate()                      // avant `.idle` : un état prêt est daté de maintenant
        // `.idle` avant l'écriture : un `startIfNeeded` arrivé pendant celle-ci relance l'abonnement.
        phase = .idle
        await saveOfflineCopy(savedAt: savedAt)
        guard generation == self.generation else { return }  // relancée pendant l'écriture : `begin` ferme l'ancien flux
        await stopFeed()
    }

    /// Écrit l'état vivant affiché dans le cache hors ligne ; jamais une copie (elle y est déjà, avec sa date).
    public func saveOfflineCopy() async {
        await saveOfflineCopy(savedAt: offlineSaveDate())
    }

    /// Date d'une copie écrite maintenant : celle du moment si l'abonnement est prêt (l'état est à jour), sinon celle
    /// du dernier état vivant reçu (conversation fermée, gardée en mémoire : elle n'est pas redatée).
    private func offlineSaveDate() -> Date {
        phase == .ready ? now() : (lastLiveAt ?? now())
    }

    private func saveOfflineCopy(savedAt: Date) async {
        guard offlineCopyDate == nil, let snapshot else { return }
        await write(snapshot, savedAt: savedAt)
    }

    /// À appeler avant `stop()` quand l'app efface la copie de cette conversation : un `stop()` tardif ne la réécrit pas.
    public func detachOfflineCache() {
        cacheDetached = true
    }

    private func write(_ snapshot: ConversationSnapshot, savedAt: Date) async {
        guard !cacheDetached, let cache, let cacheKey else { return }
        await cache.saveConversation(snapshot, key: cacheKey, savedAt: savedAt)
    }

    /// Affiche une copie hors ligne comme un état reçu, sans toucher aux réglages, aux vibrations ni à la phase.
    private func showCopy(_ copy: OfflineCopy<ConversationSnapshot>) {
        snapshot = copy.value
        offlineCopyDate = copy.savedAt                           // avant les entrées : cartes de run sans « Arrêter »
        setEntries(from: copy.value)
        let work = SessionWorkTime(rows: copy.value.rows, partial: Self.hasOlderRows(in: copy.value))
        if work != workTime { workTime = work }
        contentVersion += 1
    }

    /// Hôte injoignable (panne réseau, pas un refus) : l'état vivant affiché devient une copie hors ligne, datée du
    /// dernier état vivant reçu, et il est écrit aussitôt dans le cache (une copie déjà chargée n'est jamais réécrite).
    private func goOfflineIfPossible(retryable: Bool) {
        // Fil de sous-agent : jamais copié, il n'a pas de copie à montrer (bandeau et pagination resteraient bloqués).
        guard retryable, !readOnly, offlineCopyDate == nil, let snapshot else { return }
        let savedAt = lastLiveAt ?? now()
        offlineCopyDate = savedAt
        setEntries(from: snapshot)                               // lecture seule : plus de « Arrêter » sur les cartes
        Task { await self.write(snapshot, savedAt: savedAt) }
    }

    private func stopFeed() async {
        consumer?.cancel()
        consumer = nil
        let previous = feed
        feed = nil
        await previous?.stop()
    }

    private func handle(_ event: FeedEvent<ConversationSnapshot>, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .updated(let snapshot):
            if !readOnly {
                if settings == nil {
                    // Sans config de session il n'y a rien à initialiser : le premier `realign` écraserait un choix en cours.
                    if let config = snapshot.config {
                        settings = ComposerSettings.initial(config: config, view: catalog?.view)
                    }
                } else {
                    settings?.realign(from: self.snapshot?.config, to: snapshot.config)
                }
                // Vibrations : seulement entre deux états du même abonnement (le premier n'annonce rien de nouveau).
                if let previous = self.snapshot, interactionsGeneration == generation {
                    if previous.control?.canStop == true, snapshot.control?.canStop != true,
                       snapshot.control?.phase == .completedSuccess {
                        finishedTurns += 1
                    }
                    let known = Set(previous.pendingInteractions.map(\.interactionId))
                    if snapshot.pendingInteractions.contains(where: { !known.contains($0.interactionId) }) {
                        newInteractionAlerts += 1
                    }
                }
            }
            self.snapshot = snapshot
            if offlineCopyDate != nil { offlineCopyDate = nil }
            lastLiveAt = now()
            let pending = Set(snapshot.pendingInteractions.map(\.interactionId))
            // Nouvel abonnement : une demande que l'hôte présente encore n'a pas été prise en compte (réponse perdue,
            // redémarrage) ; elle doit réapparaître. Pas plus tôt (`begin`) : l'ancien état, encore affiché, la montrerait.
            if interactionsGeneration != generation {
                interactionsGeneration = generation
                if !answeredInteractionIds.isEmpty { answeredInteractionIds = [] }
            }
            // Retirées par l'hôte : plus rien à masquer (sans écriture inutile, observée à chaque delta).
            if !answeredInteractionIds.isSubset(of: pending) { answeredInteractionIds.formIntersection(pending) }
            snoozedInteractionIds.formIntersection(pending)
            setEntries(from: snapshot)
            let work = SessionWorkTime(rows: snapshot.rows, partial: hasOlderRows)
            if work != workTime { workTime = work }              // observé par l'en-tête seul : pas d'écriture par delta
            contentVersion += 1
            phase = .ready
            restarts = 0
            if !unconfirmed.isEmpty, reconciledGeneration != generation {
                Task { await self.reconcile(generation: generation, spaced: true) }
            }
        case .failed(let reason):
            phase = .failed(reason)
            if reason == TopicFeedFailure.connectionLost, restarts < Self.maxAutomaticRestarts {
                restarts += 1
                // L'écoute `onDidChange` du catalogue est morte avec la même connexion : `begin` la relance aussi.
                Task {
                    guard generation == self.generation else { return }
                    await self.begin(restartingCatalog: true)
                }
            } else if reason == TopicFeedFailure.connectionLost {
                goOfflineIfPossible(retryable: true)             // plus de relance automatique : l'état reste figé
            }
        }
    }

    // MARK: - Historique

    /// Charge la page précédente (une requête à la fois) ; un échec est retenté au prochain défilement.
    public func loadOlder() async {
        guard offlineCopyDate == nil, !loadingOlder, hasOlderRows, let feed, let anchor = snapshot?.rows.first?.rowId else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let agent = await connection.agent(workspace: workspace),
              let page = try? await agent.rowsRange(sessionId: sessionId, beforeRowId: anchor, limit: Self.historyPageSize),
              feed === self.feed,                                        // relancée entre-temps : la page irait à un flux arrêté
              snapshot?.rows.first?.rowId == anchor                      // fenêtre remplacée entre-temps : page jetée
        else {
            olderRowsFailed = true
            return
        }
        olderRowsFailed = await feed.mergeOlderRows(page) == false
    }

    /// Pages lues au plus par « Chercher plus loin ».
    public static let searchPagesPerGesture = 10

    /// « Chercher plus loin » : charge l'historique page par page jusqu'à une correspondance de `query`, le début de
    /// la conversation ou `maxPages` pages.
    public func searchOlder(_ query: String, maxPages: Int = searchPagesPerGesture) async -> OlderSearchOutcome {
        for _ in 0..<maxPages {
            guard hasOlderRows, let anchor = snapshot?.rows.first?.rowId else { return .exhausted }
            await loadOlder()
            guard !olderRowsFailed, await waitForRows(before: anchor) else { return .failed }
            if let id = ConversationSearch.matchingIds(in: ungroupedEntries.filter { $0.id < anchor }, query: query).last {
                return .found(id)
            }
        }
        return hasOlderRows ? .limitReached : .exhausted
    }

    /// Attend que la page fusionnée soit publiée (`snapshot` et `entries` arrivent par le flux), 1 s au plus. Une page
    /// chargée au même moment par le défilement (`loadOlder` déjà en cours) compte aussi.
    private func waitForRows(before anchor: Int) async -> Bool {
        for _ in 0..<20 {
            if let first = snapshot?.rows.first?.rowId, first < anchor { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Fichiers modifiés par un tour

    static let fileChangesAttempts = 3

    /// Fichiers modifiés par un tour (`conversationFileChangesV4`, cible = son en-tête). L'hôte exige la révision exacte
    /// de son snapshot : pendant un tour en cours elle avance sans cesse (`proto.staleRevision`), d'où trois essais au
    /// plus, chacun à la dernière révision reçue (attendue 300 ms au plus).
    public func fileChanges(for target: RowTarget) async -> TurnChangesLoad {
        for attempt in 1...Self.fileChangesAttempts {
            guard let base = snapshot?.commandBase, let agent = await connection.agent(workspace: workspace) else {
                return .failed(connection.failure?.message ?? "Conversation indisponible : réessaie.")
            }
            do {
                return .loaded(try await agent.fileChanges(sessionId: sessionId, target: target, base: base))
            } catch {
                let reason = Self.remoteMessage(error)
                guard Self.isStale(reason), attempt < Self.fileChangesAttempts else {
                    return .failed(Self.fileChangesFailure(reason, error))
                }
                await waitForRevision(after: base)
            }
        }
        return .failed("La conversation a changé pendant le chargement : réessaie.")
    }

    /// Attend qu'un état plus récent arrive (300 ms au plus).
    private func waitForRevision(after base: CommandBase) async {
        for _ in 0..<6 {
            if let current = snapshot?.commandBase, current != base { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func remoteMessage(_ error: any Error) -> String {
        if case RPCError.remote(let remote) = error { return remote.message }
        return ""
    }

    private static func isStale(_ reason: String) -> Bool {
        reason.contains("proto.staleRevision") || reason.contains("proto.staleLogEpoch")
    }

    private static func fileChangesFailure(_ reason: String, _ error: any Error) -> String {
        if isStale(reason) { return "La conversation a changé pendant le chargement : réessaie." }
        if reason.contains("fault.fileChanges.unsupported") {
            return "Cet hôte ne fournit pas le détail des fichiers modifiés : ouvre l'interface web."
        }
        if reason.contains("proto.staleTarget") || reason.contains("guard.actionUnavailable") {
            return "Ce tour n'est plus disponible : actualise la conversation."
        }
        if reason.contains("sessionNotFound") { return "Session introuvable sur l'hôte." }
        return reason.isEmpty ? ConnectionFailure(error).message : reason
    }

    // MARK: - Commandes

    /// Envoie `text` ; l'hôte décide de démarrer, mettre en file ou guider d'après `inputRouting`.
    public func send(_ text: String, heldQueue: CommandBuilder.HeldQueueChoice? = nil) async -> SendOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !sending else { return .failed }
        guard canSendAttachments else {
            commandError = "Pièce jointe en cours d'envoi : attends la fin du téléversement."
            return .failed
        }
        commandNotice = nil                                                   // tout envoi efface l'avis précédent
        // `/plan` passe avant tout, `/compact` sans pièce jointe (règles du web) ; le reste part tel quel.
        switch SlashSendCommand.parse(text, hasAttachments: !attachments.isEmpty) {
        case .planWithAttachments?:
            commandError = ChatLabels.planWithAttachments
            return .failed
        case .plan(let task)?:
            selectMode(ModeOption.plan)
            guard !task.isEmpty else { return .sent(delivery: nil) }          // bascule seule : rien n'est envoyé
            return await sendMessage(task, heldQueue: heldQueue)              // la tâche seule, avec planEnabled
        case .compact?:
            return await compact()
        case nil:
            break
        }
        if let command = GoalCommand.parse(text) {
            guard attachments.isEmpty else {
                commandError = "Un Goal ne prend pas de pièce jointe : retire-la ou envoie un message."
                return .failed
            }
            return await sendGoalCommand(command, typed: text, heldQueue: heldQueue)
        }
        return await sendMessage(text, heldQueue: heldQueue)
    }

    /// Message ordinaire (`sendText`) : choix de file, pièces jointes, réglages du composeur.
    private func sendMessage(_ text: String, heldQueue: CommandBuilder.HeldQueueChoice?) async -> SendOutcome {
        let heldItemIds = snapshot?.queue?.items.map(\.queueItemId) ?? []
        if routing == "choice", heldQueue == nil { return .needsQueueChoice(itemIds: heldItemIds) }
        // Plus de 8 : possible si un envoi abandonné a rendu ses pièces jointes à un composeur déjà garni.
        guard attachments.count <= Self.maxAttachments else {
            commandError = Self.tooManyAttachments
            return .failed
        }
        let refs = attachments.compactMap(\.reference)
        let body = text.isEmpty ? Self.attachmentOnlyText : text
        sending = true
        defer { sending = false }
        var envelope = builder.sendText(sessionId: sessionId, text: body, heldQueue: heldQueue, attachments: refs)
        if let settings {
            switch settings.submission(in: catalog?.view) {
            case .success(let submission):
                envelope = builder.sendText(sessionId: sessionId, text: body, modelSelection: submission.modelSelection,
                                            mode: submission.mode, planEnabled: submission.planEnabled,
                                            heldQueue: heldQueue, attachments: refs)
            case .failure(let issue):
                commandError = issue.message
                return .failed
            }
        }
        let outcome = await submit(envelope)
        // Invariant : aucune suspension entre le retour de `submit` et ce retrait, donc un `giveUp` qui rend ces pièces
        // jointes ne peut pas passer avant.
        switch outcome {
        case .sent, .unconfirmed:
            // Parties (ou gardées pour le rapprochement, qui les rendra en cas d'abandon).
            attachments.removeAll { item in item.reference.map(refs.contains) ?? false }
        case .failed, .needsQueueChoice:
            break
        }
        return outcome
    }

    /// Envoi d'un message ou d'un Goal : rapprochement d'un envoi coupé, choix de file reposé si l'hôte le demande.
    private func submit(_ envelope: CommandEnvelope) async -> SendOutcome {
        let ack: CommandAck
        switch await transmit(envelope) {
        case .acknowledged(let received):
            ack = received
            commandError = ack.isAccepted ? nil : ChatLabels.refusal(ack)
        case .notSent, .rejected:
            return .failed
        case .uncertain:
            return .unconfirmed
        case .garbled:
            // L'hôte a répondu, mais on ne sait pas s'il a traité la commande : on l'interroge tout de suite, sans
            // attendre une reconnexion (un passage en cours repart à sa fin : voir `reconcile`).
            let generation = self.generation
            Task { await self.reconcile(generation: generation, spaced: false) }
            return .unconfirmed
        }
        if !ack.isAccepted, ack.reasonCode == "guard.heldQueueConfirmationStale" || ack.reasonCode == "heldQueueDispositionRequired" {
            commandError = nil                                   // pas une erreur : la question est reposée
            return .needsQueueChoice(itemIds: snapshot?.queue?.items.map(\.queueItemId) ?? [])
        }
        return ack.isAccepted ? .sent(delivery: ack.result?.delivery) : .failed
    }

    // MARK: - Pièces jointes

    /// Toutes les pièces jointes sont téléversées (ou il n'y en a pas) : le message peut partir.
    public var canSendAttachments: Bool { attachments.allSatisfy(\.isReady) }

    /// Ajoute une pièce jointe au prochain message et la téléverse aussitôt ; `false` (raison dans `commandError`) si elle
    /// dépasse les bornes de l'hôte. Le nom et le type sont assainis comme l'hôte l'exige (sinon il refuse dès le début).
    @discardableResult
    public func attach(data: Data, fileName: String, mime: String, thumbnail: Data? = nil) -> Bool {
        guard attachments.count < Self.maxAttachments else {
            commandError = Self.tooManyAttachments
            return false
        }
        guard data.count <= Self.maxAttachmentBytes else {
            commandError = "Fichier trop gros : 20 Mo au plus par pièce jointe."
            return false
        }
        let item = ComposerAttachment(id: UUID(), fileName: Self.sanitizedFileName(fileName), mime: Self.sanitizedMime(mime),
                                      bytes: data.count, thumbnail: thumbnail, state: .uploading)
        attachments.append(item)
        pendingUploadData[item.id] = data
        startUpload(item.id)
        return true
    }

    /// Images lues pour l'affichage : 32 au plus et 24 Mio au total, les plus anciennes oubliées.
    @ObservationIgnored private var attachmentCache: [String: Data] = [:]
    @ObservationIgnored private var attachmentCacheOrder: [String] = []
    @ObservationIgnored private var attachmentCacheBytes = 0
    static let attachmentCacheMaxEntries = 32
    static let attachmentCacheMaxBytes = 24 * 1024 * 1024

    /// Contenu d'une image jointe à un message, pour sa vignette ; `nil` pour un document ou si la lecture échoue.
    public func attachmentData(for attachment: AttachmentRef) async -> Data? {
        guard attachment.isImage else { return nil }
        let key = attachment.readableRef
        if let cached = attachmentCache[key] { return cached }
        guard let agent = await connection.agent(workspace: workspace),
              let data = try? await agent.readAttachment(sessionId: sessionId, ref: key) else { return nil }
        cacheAttachment(data, for: key)
        return data
    }

    private func cacheAttachment(_ data: Data, for key: String) {
        guard data.count <= Self.attachmentCacheMaxBytes else { return }        // seule, elle viderait le cache
        if let old = attachmentCache.updateValue(data, forKey: key) {
            attachmentCacheBytes -= old.count                                    // lecture concurrente de la même image
        } else {
            attachmentCacheOrder.append(key)
        }
        attachmentCacheBytes += data.count
        while attachmentCacheOrder.count > Self.attachmentCacheMaxEntries || attachmentCacheBytes > Self.attachmentCacheMaxBytes {
            let oldest = attachmentCacheOrder.removeFirst()
            attachmentCacheBytes -= attachmentCache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    public func removeAttachment(_ id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        pendingUploadData[id] = nil
        attachments.removeAll { $0.id == id }
    }

    /// Nouvel essai d'une pièce jointe en échec.
    public func retryAttachment(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }), case .failed = attachments[index].state,
              pendingUploadData[id] != nil else { return }
        attachments[index].state = .uploading
        startUpload(id)
    }

    /// Sans `\0`, retour chariot ni saut de ligne, rogné, 255 caractères au plus ; « Pièce jointe » s'il ne reste rien.
    static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name.filter { $0 != "\0" && !$0.isNewline }.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(cleaned.prefix(255)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? "Pièce jointe" : clipped
    }

    /// Le type tel quel s'il a la forme `type/sous-type`, sinon `application/octet-stream`.
    static func sanitizedMime(_ mime: String) -> String {
        let token = "[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*"
        let trimmed = mime.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^\(token)/\(token)$", options: .regularExpression) != nil ? trimmed : "application/octet-stream"
    }

    private func startUpload(_ id: UUID) {
        uploads[id] = Task { await upload(id) }
    }

    private func upload(_ id: UUID) async {
        defer { uploads[id] = nil }
        guard let item = attachments.first(where: { $0.id == id }), let data = pendingUploadData[id] else { return }
        guard let agent = await connection.agent(workspace: workspace) else {
            guard !Task.isCancelled else { return }
            setAttachmentState(id, .failed(connection.failure?.message ?? "Hôte injoignable."))
            return
        }
        do {
            let ref = try await agent.uploadAttachment(sessionId: sessionId, fileName: item.fileName, mime: item.mime, data: data)
            guard !Task.isCancelled else { return }
            pendingUploadData[id] = nil
            setAttachmentState(id, .ready(ref))
        } catch {
            guard !Task.isCancelled else { return }
            setAttachmentState(id, .failed(ChatLabels.attachmentFailure(error)))
        }
    }

    /// Sans effet si la pièce jointe a été retirée entre-temps.
    private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    /// Pièces jointes d'un envoi abandonné après coup : rendues au composeur, prêtes (références valables 24 h).
    private func returnAttachments(of envelope: CommandEnvelope) {
        let refs = envelope.payload["attachments"]?.arrayValue?.compactMap { try? V4JSON.decode(AttachmentRef.self, from: $0) } ?? []
        let restored = refs.filter { ref in !attachments.contains { $0.reference == ref } }.map {
            ComposerAttachment(id: UUID(), fileName: $0.fileName, mime: $0.mime, bytes: $0.bytes, thumbnail: nil, state: .ready($0))
        }
        attachments = restored + attachments
    }

    // MARK: - Goal

    /// Au-delà, l'hôte refuse l'objectif (`MAX_GOAL_OBJECTIVE_CHARS`).
    public static let maxGoalObjectiveLength = 4_000

    public var goal: GoalState? { snapshot?.goal }

    public var canPauseGoal: Bool { !isLocked && snapshot?.availability["pauseGoal"]?.allowed == true }

    public var canResumeGoal: Bool { !isLocked && snapshot?.availability["resumeGoal"]?.allowed == true }

    /// Lance (ou remplace) le Goal depuis la fiche ; montré dans la conversation comme « /goal objectif ».
    public func startGoal(_ objective: String, heldQueue: CommandBuilder.HeldQueueChoice? = nil) async -> SendOutcome {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        return await startGoal(objective, displayText: "/goal " + objective, heldQueue: heldQueue)
    }

    public func pauseGoal() async {
        await performCAS { builder.pauseGoal(sessionId: sessionId, base: $0) }
    }

    public func resumeGoal() async {
        await performCAS { builder.resumeGoal(sessionId: sessionId, base: $0) }
    }

    private func sendGoalCommand(_ command: GoalCommand, typed: String, heldQueue: CommandBuilder.HeldQueueChoice?) async
        -> SendOutcome {
        switch command {
        case .set(let objective):
            return await startGoal(objective, displayText: typed, heldQueue: heldQueue)
        case .resume:
            await resumeGoal()
            return commandError == nil ? .sent(delivery: nil) : .failed
        case .unsupported, .empty:
            commandError = command.refusal
            return .failed
        }
    }

    /// L'objectif part seul (l'hôte ne retire pas « /goal ») ; `displayText` est ce qui s'affiche dans la conversation.
    private func startGoal(_ objective: String, displayText: String, heldQueue: CommandBuilder.HeldQueueChoice?) async
        -> SendOutcome {
        guard !objective.isEmpty else {
            commandError = GoalCommand.empty.refusal
            return .failed
        }
        guard objective.count <= Self.maxGoalObjectiveLength else {
            commandError = "Objectif trop long (4 000 caractères au plus)."
            return .failed
        }
        guard !sending else { return .failed }
        if routing == "choice", heldQueue == nil {
            return .needsQueueChoice(itemIds: snapshot?.queue?.items.map(\.queueItemId) ?? [])
        }
        var envelope = builder.sendGoal(sessionId: sessionId, objective: objective, displayText: displayText, heldQueue: heldQueue)
        if let settings {
            switch settings.submission(in: catalog?.view) {
            case .success(let submission):
                guard !submission.planEnabled else {
                    commandError = ChatLabels.goalInPlanMode
                    return .failed
                }
                envelope = builder.sendGoal(sessionId: sessionId, objective: objective, displayText: displayText,
                                            modelSelection: submission.modelSelection, mode: submission.mode,
                                            planEnabled: submission.planEnabled, heldQueue: heldQueue)
            case .failure(let issue):
                commandError = issue.message
                return .failed
            }
        }
        sending = true
        defer { sending = false }
        return await submit(envelope)
    }

    // MARK: - File d'attente

    /// Messages en file (hors messages qui guident le tour en cours).
    public var queuedItems: [QueueItem] { snapshot?.queue?.items.filter { !$0.isGuide } ?? [] }

    /// Messages admis pour guider le tour en cours, affichés en fin de conversation.
    public var guideItems: [QueueItem] { snapshot?.queue?.items.filter(\.isGuide) ?? [] }

    public var queuePaused: Bool { snapshot?.queue?.autoDrain == false && !queuedItems.isEmpty }

    public var canSendQueuedNow: Bool { snapshot?.availability["sendQueuedNow"]?.allowed == true }

    public func deleteQueued(_ queueItemId: String) async {
        await performCAS { builder.deleteQueueItem(sessionId: sessionId, queueItemId: queueItemId, base: $0) }
    }

    public func sendQueuedNow(_ queueItemId: String) async {
        await performCAS { builder.sendQueuedNow(sessionId: sessionId, queueItemId: queueItemId, base: $0) }
    }

    /// Relance une file mise en pause par un arrêt ou un échec.
    public func resumeQueue() async {
        await performCAS { builder.setAutoDrain(sessionId: sessionId, autoDrain: true, base: $0) }
    }

    /// Commande CAS : renvoyée avec la révision du serveur tant qu'elle est périmée (3 essais). Rend le dernier accusé,
    /// `nil` si la commande n'a pas pu partir ou n'a pas reçu d'accusé lisible.
    @discardableResult
    private func performCAS(_ make: (CommandBase) -> CommandEnvelope) async -> CommandAck? {
        guard var base = snapshot?.commandBase else { return nil }
        let attempts = 3
        var last: CommandAck?
        for attempt in 1...attempts {
            // Un refus « périmé » n'est pas montré tant qu'il reste un essai : seul le dernier échec compte.
            guard let ack = await perform(make(base), retryingIfStale: attempt < attempts) else { return nil }
            last = ack
            guard ack.status == .stale, let revision = ack.revisionAtDecision else { return ack }
            base = CommandBase(revision: revision, logEpoch: base.logEpoch)
        }
        return last
    }

    /// Ligne de la réponse que l'hôte permet de relancer (`actions.canRetry`), hors tour en cours ; c'est aussi l'`id`
    /// de son `ChatEntry`.
    public var retryEntryId: Int? {
        guard !isLocked, snapshot?.control?.canStop != true else { return nil }
        return retryTarget?.rowId
    }

    private var retryTarget: RowTarget? {
        snapshot?.rows.last { $0.kind == .assistantText && $0.actions.canRetry }.flatMap(RowTarget.init(row:))
    }

    /// Relance la dernière réponse : l'hôte coupe la conversation après le message et rejoue le tour.
    public func retryLastResponse() async {
        guard retryEntryId != nil, let target = retryTarget else { return }
        await performCAS { builder.retryTurn(sessionId: sessionId, target: target, base: $0) }
    }

    /// Réponses que l'hôte permet de prendre comme point de départ d'une nouvelle session (`actions.canFork`, seul juge).
    public var forkableRowIds: Set<Int> {
        guard !isLocked else { return [] }
        return Set(snapshot?.rows.filter { $0.kind == .assistantText && $0.actions.canFork }.map(\.rowId) ?? [])
    }

    /// « Repartir d'ici » : `forkAssistant` CAS sur la réponse (nouvel essai si la base est périmée) ; rend la session
    /// enfant à ouvrir, `nil` si l'hôte refuse (`commandError` posé) ou si la ligne ne s'y prête pas.
    public func fork(rowId: Int) async -> String? {
        guard !forking else { return nil }                  // double appui : un seul `forkAssistant`
        forking = true
        defer { forking = false }
        guard forkableRowIds.contains(rowId), let row = snapshot?.row(id: rowId), let target = RowTarget(row: row),
              let ack = await performCAS({ builder.forkAssistant(sessionId: sessionId, target: target, base: $0) }),
              ack.isAccepted else { return nil }
        guard let child = ack.result?.sessionId else {
            commandError = "Session dérivée créée, mais l'hôte n'a pas donné son identifiant : ouvre-la depuis la liste."
            return nil
        }
        return child
    }

    // MARK: - Runs de workflow

    /// Cartes des runs de workflow de la session, dans l'ordre des runs (calculées depuis l'état affiché et `isLocked`).
    public var workflowCards: [WorkflowRunCard] {
        snapshot.map(workflowCards(for:)) ?? []
    }

    private func workflowCards(for snapshot: ConversationSnapshot) -> [WorkflowRunCard] {
        WorkflowRunCard.cards(runs: snapshot.workflowRuns, works: snapshot.backgroundWorks, rows: snapshot.rows, locked: isLocked)
    }

    /// Entrées à plat : lignes du serveur, puis cartes des runs insérées à leur place.
    private func composedEntries(_ snapshot: ConversationSnapshot) -> [ChatEntry] {
        ChatTimeline.inserting(workflowCards(for: snapshot), into: ChatTimeline.entries(from: snapshot.rows))
    }

    /// Recompose les entrées à plat puis les groupes (lot 13I).
    private func setEntries(from snapshot: ConversationSnapshot) {
        ungroupedEntries = composedEntries(snapshot)
        regroupEntries()
    }

    /// Regroupe les entrées à plat selon les groupes dépliés et les demandes ouvertes.
    private func regroupEntries() {
        let pending = Set((snapshot?.pendingInteractions ?? []).map(\.interactionId))
        entries = ChatTimeline.grouping(ungroupedEntries, expanded: expandedToolGroups, pendingInteractionIds: pending)
    }

    /// Plie ou déplie un groupe de cartes. Les identifiants sans groupe sont gardés : un groupe peut revenir après rechargement.
    public func toggleToolGroup(_ id: Int) {
        if !expandedToolGroups.insert(id).inserted { expandedToolGroups.remove(id) }
        regroupEntries()
    }

    /// Déplie le groupe qui contient `entryId` (recherche) ; sans effet sinon.
    public func reveal(entryId: Int) {
        guard let id = ChatTimeline.toolGroupId(containing: entryId, in: ungroupedEntries),
              expandedToolGroups.insert(id).inserted else { return }
        regroupEntries()
    }

    /// Arrête un run (`cancelBackgroundWork`) ; un refus de l'hôte est traduit par son code de raison.
    public func cancelWorkflowRun(_ runId: String) async {
        guard !isLocked else { return }
        guard let ack = await perform(builder.cancelBackgroundWork(sessionId: sessionId, workId: runId)) else { return }
        if !ack.isAccepted, ack.status != .noop {
            commandError = WorkflowLabels.cancelRefusal(reasonCode: ack.reasonCode)
        }
    }

    /// Arrête le tour en cours (première exécution au premier plan, comme l'interface web).
    public func stopTurn() async {
        guard let control = snapshot?.control, control.canStop == true else { return }
        let expected = control.activeWorks?.first { $0.foregroundExecutionId != nil }?.foregroundExecutionId
        await perform(builder.stop(sessionId: sessionId, expectedForegroundExecutionId: expected))
    }

    /// Rend le texte abandonné (une seule fois) pour le remettre dans le brouillon.
    public func takeReturnedDraft() -> String? {
        defer { returnedDraft = nil }
        return returnedDraft
    }

    public func dismissCommandError() {
        commandError = nil
    }

    /// Envoie une commande ; `nil` (erreur affichée) si elle n'a pas pu être transmise. Seuls `sendText` et
    /// `sendGoalCommand` (via `submit`) sont rapprochés : un stop ou une commande de file perdus se refont à la main.
    @discardableResult
    private func perform(_ envelope: CommandEnvelope, retryingIfStale: Bool = false) async -> CommandAck? {
        switch await transmit(envelope) {
        case .acknowledged(let ack):
            // `noop` : rien à faire (ex. stop d'un tour déjà terminé), pas une erreur pour l'utilisateur.
            let willRetry = retryingIfStale && ack.status == .stale && ack.revisionAtDecision != nil
            commandError = ack.isAccepted || ack.status == .noop || willRetry ? nil : ChatLabels.refusal(ack)
            return ack
        case .notSent, .rejected:
            return nil
        case .uncertain:
            forget(envelope)
            commandError = "Connexion perdue : commande peut-être non transmise."
            return nil
        case .garbled:
            forget(envelope)
            commandError = "Réponse de l'hôte illisible : commande peut-être exécutée, vérifie la conversation."
            return nil
        }
    }

    // MARK: - Compression

    /// `/compact` (`/compress`) : commande `compact {}` sans CAS ni choix de file ; un tour en cours la fait mettre en
    /// file par l'hôte. Le texte qui suit la commande est ignoré, comme sur le web.
    private func compact() async -> SendOutcome {
        let queued = routing != "startNow"
        guard let ack = await perform(builder.compact(sessionId: sessionId)) else { return .failed }
        if ack.isAccepted || ack.status == .noop {
            if queued, ack.isAccepted { commandNotice = ChatLabels.compactQueued }
            return .sent(delivery: nil)
        }
        if ack.reasonCode == "activeTurn" { commandError = ChatLabels.compactBusy }   // hôte plus ancien
        return .failed
    }

    public func dismissCommandNotice() {
        commandNotice = nil
    }

    // MARK: - Approbations et questions

    /// Demandes que l'app sait présenter (autorisations, questions), dans l'ordre de l'hôte, sauf celles déjà répondues.
    private var answerableInteractions: [PendingInteraction] {
        (snapshot?.pendingInteractions ?? []).filter { interaction in
            switch interaction.payload {
            case .permission, .userInput: !answeredInteractionIds.contains(interaction.interactionId)
            case .unsupported: false
            }
        }
    }

    /// Demande affichée à la place du composeur : la première, comme dans l'interface web ; les autres suivent.
    public var currentInteraction: PendingInteraction? { answerableInteractions.first }

    /// Autres demandes en attente derrière celle affichée (appels d'outils parallèles).
    public var queuedInteractionCount: Int { max(answerableInteractions.count - 1, 0) }

    /// Demandes que l'app ne traite pas (revue des hooks, type inconnu, contenu illisible) : à faire dans l'interface web.
    public var unsupportedInteractionCount: Int {
        (snapshot?.pendingInteractions ?? []).filter { $0.payload == .unsupported }.count
    }

    /// Répond à une demande ; `true` si l'hôte l'a prise en compte. Jamais renvoyée seule (ZCode §6.2) : si la réponse
    /// s'est perdue, la demande reste affichée et l'utilisateur répond à nouveau (une réponse tardive vaut `noop`).
    @discardableResult
    public func respond(to interaction: PendingInteraction, with answer: InteractionAnswer) async -> Bool {
        guard respondingInteractionId == nil else { return false }
        respondingInteractionId = interaction.interactionId
        defer { respondingInteractionId = nil }
        let envelope = builder.resolveInteraction(sessionId: sessionId, interactionId: interaction.interactionId, answer: answer)
        switch await transmit(envelope, keepingUncertain: false) {
        case .acknowledged(let ack) where ack.isAccepted || ack.status == .noop:
            // `noop` : un autre appareil a répondu le premier ; la demande disparaît au prochain état de l'hôte.
            commandError = nil
            answeredInteractionIds.insert(interaction.interactionId)
            return true
        case .acknowledged(let ack):
            commandError = ChatLabels.refusal(ack)
            return false
        case .notSent, .rejected:
            return false
        case .uncertain, .garbled:
            commandError = "Réponse peut-être non transmise : si la demande reste affichée, réponds à nouveau."
            return false
        }
    }

    /// À la première action sur une question à compte à rebours : l'agent ne répond plus seul à la fin du délai. Une
    /// commande par demande ; retentée à l'action suivante si l'hôte ne l'a pas confirmée.
    public func pauseAutoResolution(of interaction: PendingInteraction) async {
        let id = interaction.interactionId
        guard let auto = interaction.autoResolution, !auto.isSnoozed, !snoozedInteractionIds.contains(id) else { return }
        snoozedInteractionIds.insert(id)
        let envelope = builder.snoozeAutoResolution(sessionId: sessionId, interactionId: id)
        if case .acknowledged(let ack) = await transmit(envelope, keepingUncertain: false),
           ack.isAccepted || ack.status == .noop {
            return
        }
        snoozedInteractionIds.remove(id)
    }

    // MARK: - Reprise d'un envoi coupé

    private enum Transmission {
        case acknowledged(CommandAck)
        /// Rien n'est parti (hôte injoignable) : un renvoi reste gardé pour la reprise.
        case notSent
        /// L'hôte a répondu par une erreur (`commandError` renseigné) : renvoyer donnerait la même réponse.
        case rejected
        /// Parti, réponse perdue : gardé pour le rapprochement.
        case uncertain
        /// L'hôte a répondu, mais de façon illisible (`AgentV4Error`) : peut-être traité. Gardé comme `uncertain`,
        /// mais la connexion est vivante : l'appelant peut interroger l'hôte sans attendre.
        case garbled
    }

    /// `keepingUncertain` : un envoi parti sans accusé est gardé pour le rapprochement (renvoi tel quel) ; `false` pour
    /// les commandes qui ne doivent jamais repartir seules (réponse à une demande, ZCode §6.2).
    private func transmit(_ envelope: CommandEnvelope, keepingUncertain: Bool = true) async -> Transmission {
        guard let agent = await connection.agent(workspace: workspace) else {
            commandError = connection.failure?.message ?? "Hôte injoignable."
            return .notSent
        }
        do {
            return .acknowledged(try await agent.send(envelope))
        } catch RPCError.remote(let remote) {
            commandError = "Commande refusée par l'hôte (\(remote.message))."
            return .rejected
        } catch RPCError.errorObject {
            commandError = "Commande refusée par l'hôte."
            return .rejected
        } catch is AgentV4Error {
            if keepingUncertain { keepUnconfirmed(envelope) }
            return .garbled
        } catch {
            if keepingUncertain { keepUnconfirmed(envelope) }
            return .uncertain
        }
    }

    private func keepUnconfirmed(_ envelope: CommandEnvelope) {
        if !unconfirmed.contains(where: { $0.key == envelope.key }) { unconfirmed.append(envelope) }   // renvoi : déjà gardé
        unconfirmedCount = unconfirmed.count
    }

    /// Interroge l'hôte sur les envois sans accusé. Un passage déjà en cours repart à sa fin (`rerunRequested`) au lieu
    /// de perdre la demande ; un abonnement dépassé est repris par le passage de l'abonnement suivant. Un passage sans
    /// issue est réessayé après un délai croissant (`reconcileRetryDelays`) tant que la connexion vit : le plafond par
    /// envoi le borne. `spaced` : le passage vient d'un nouvel abonnement ou du délai d'attente (il peut coûter un essai à
    /// tous les envois) ; sinon il suit un nouvel envoi illisible et n'en coûte qu'aux envois jamais encore comptés — au
    /// plus un essai par envoi et par appel, et jamais plus d'un par délai écoulé.
    private func reconcile(generation: Int, spaced: Bool) async {
        guard generation == self.generation, !unconfirmed.isEmpty else { return }
        // Avant le premier snapshot l'abonnement n'est pas rapproché : `handle` relancera un passage à son arrivée.
        if phase == .ready { reconciledGeneration = generation }
        if reconciling {
            rerunRequested = true
            return
        }
        reconciling = true
        var inconclusive = false
        var spaced = spaced
        repeat {
            rerunRequested = false
            let outcome = await reconcilePass(generation: generation, spaced: spaced)
            inconclusive = inconclusive || outcome
            spaced = false                                           // la relance d'un passage en cours ne coûte rien aux autres
        } while rerunRequested && generation == self.generation && !unconfirmed.isEmpty
        reconciling = false
        rerunRequested = false
        if generation == self.generation {
            if inconclusive, !unconfirmed.isEmpty, phase == .ready { scheduleRetry(generation: generation) }
        } else if phase == .ready, reconciledGeneration != self.generation, !unconfirmed.isEmpty {
            // Un nouvel abonnement a livré son premier état pendant ce passage : il n'a pas pu être rapproché.
            await reconcile(generation: self.generation, spaced: true)
        }
    }

    private func scheduleRetry(generation: Int) {
        retryTask?.cancel()
        let lost = max(attempts.values.max() ?? 1, 1)
        let delay = reconcileRetryDelays[min(lost, reconcileRetryDelays.count) - 1]
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == self.generation, self.phase == .ready else { return }
            await self.reconcile(generation: generation, spaced: true)
        }
    }

    /// Un passage : renvoie tels quels (même `commandId`) les envois que l'hôte n'a jamais reçus. Un envoi n'est oublié
    /// que sur réponse définitive de l'hôte (accusé, refus ou erreur) ; hôte injoignable, il reste gardé pour la reprise
    /// suivante (une coupure ne compte pas). Un envoi laissé sans issue — l'hôte répond par une erreur ou une réponse
    /// illisible à la requête, répond `queryUnavailable`, ne la connaît pas du tout, ou son renvoi reste illisible — coûte
    /// un essai (si `spaced`, ou s'il n'en a encore perdu aucun : voir `reconcile`) ; à `maxReconcileFailures` essais il
    /// est abandonné, sans quoi la bannière « non confirmé » ne se fermerait jamais. Rend `true` si un envoi est resté
    /// sans issue (compté ou non) : un nouveau passage est à prévoir après le délai.
    private func reconcilePass(generation: Int, spaced: Bool) async -> Bool {
        let pending = unconfirmed
        guard let agent = await connection.agent(workspace: workspace), generation == self.generation else { return false }
        let results: [CommandQueryItem]
        do {
            results = try await agent.queryCommands(pending.map(\.key))
        } catch {
            guard generation == self.generation, Self.isHostAnswer(error) else { return false }   // coupure : à la reprise
            pending.forEach { charge($0, spaced: spaced) }
            return true
        }
        var inconclusive = false
        for envelope in pending {
            guard generation == self.generation else { break }
            guard let item = results.first(where: { $0.key == envelope.key }) else {
                charge(envelope, spaced: spaced)                  // question sans réponse : sans issue
                inconclusive = true
                continue
            }
            switch item.result {
            case .known(let ack) where ack.status == .failed && ack.reasonCode == "fault.command.queryUnavailable":
                charge(envelope, spaced: spaced)                  // l'hôte ne peut pas encore répondre : on garde
                inconclusive = true
            case .known(let ack):
                settle(envelope, with: ack)
            case .unknown:
                switch await transmit(envelope) {
                case .acknowledged(let ack): settle(envelope, with: ack)
                case .rejected: giveUp(envelope)                  // `commandError` posé par `transmit`
                case .garbled:                                    // renvoi illisible : pas de passe demandée, le délai s'en charge
                    charge(envelope, spaced: spaced)
                    inconclusive = true
                case .notSent, .uncertain: break                  // gardé pour la reprise
                }
            }
        }
        return inconclusive
    }

    /// Un essai de plus sans issue pour `envelope` ; au plafond, il est abandonné (texte rendu, message d'avertissement).
    /// Hors passage `spaced`, seul un envoi sans essai perdu est compté : un nouvel envoi illisible ne ronge pas le
    /// budget des précédents.
    private func charge(_ envelope: CommandEnvelope, spaced: Bool) {
        guard unconfirmed.contains(where: { $0.key == envelope.key }) else { return }
        guard spaced || attempts[envelope.key] == nil else { return }
        let count = attempts[envelope.key, default: 0] + 1
        if count >= Self.maxReconcileFailures {
            giveUp(envelope)
            commandError = "Envoi non confirmé par l'hôte : vérifie dans la conversation si ton message est passé avant de le renvoyer (il est remis dans le composeur)."
        } else {
            attempts[envelope.key] = count
        }
    }

    /// L'hôte a répondu (erreur ou réponse illisible), par opposition à une coupure.
    private static func isHostAnswer(_ error: any Error) -> Bool {
        switch error {
        case RPCError.remote, RPCError.errorObject, is AgentV4Error: true
        default: false
        }
    }

    private func settle(_ envelope: CommandEnvelope, with ack: CommandAck) {
        if ack.isAccepted {
            forget(envelope)
        } else {
            commandError = ChatLabels.refusal(ack)
            giveUp(envelope)
        }
    }

    /// Oublie un envoi refusé ou abandonné et rend son texte au composeur (qui avait vidé le brouillon).
    private func giveUp(_ envelope: CommandEnvelope) {
        forget(envelope)
        // Un Goal rend le texte saisi (« /goal … ») : son `text` n'est que l'objectif.
        let text: String? = switch envelope.type {
        case .sendText: envelope.payload["text"]?.stringValue
        case .sendGoalCommand: envelope.payload["displayText"]?.stringValue ?? envelope.payload["text"]?.stringValue.map { "/goal " + $0 }
        default: nil
        }
        guard let text else { return }
        returnAttachments(of: envelope)
        guard !text.isEmpty else { return }                      // pièces jointes seules : pas de brouillon à rendre
        returnedDraft = returnedDraft.map { "\($0)\n\n\(text)" } ?? text
    }

    private func forget(_ envelope: CommandEnvelope) {
        unconfirmed.removeAll { $0.key == envelope.key }
        unconfirmedCount = unconfirmed.count
        attempts[envelope.key] = nil
    }
}
