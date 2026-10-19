import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Catalogue du panneau « / » d'un projet d'un hôte : commandes (`readWorkspacePresentation`), skills
/// (`getSkillReferenceCatalog`) et sous-agents (`SubagentsModel` de la portée du projet), lus ensemble. Relu à
/// l'ouverture d'une conversation ou du panneau s'il a plus de 5 minutes ; une source en échec retire sa section sans
/// bloquer les autres. Skills rangées par autorité : une session avec historique (catalogue figé) ou le projet.
@MainActor
@Observable
public final class SlashCatalog {
    public static let maxAge: TimeInterval = 300
    /// Décision D2 de la tâche 0 : `true` si le catalogue d'une session ancienne reste illisible après l'abonnement (on
    /// lit alors celui du projet) ; `false` : comme le web, la section disparaît.
    public static let fallsBackToWorkspaceSkills = false

    private struct CachedSkills {
        let entries: [SlashEntry]?
        let at: Date
    }

    public let workspace: String
    /// `nil` : jamais lues ou lecture en échec (section absente).
    public private(set) var commands: [SlashEntry]?
    public private(set) var subagents: [SlashEntry]?
    public private(set) var isLoading = false
    /// Clé : identifiant de session, `""` pour le projet.
    private var skillsByAuthority: [String: CachedSkills] = [:]
    @ObservationIgnored private var workspaceLoadedAt: Date?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    private let connection: HostConnection
    private let subagentsModel: SubagentsModel
    /// Repli sur le catalogue du projet quand celui d'une session est illisible (lecture seule : testé par `AppModel`).
    public let skillsFallback: Bool
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(connection: HostConnection, workspace: String, subagents: SubagentsModel,
                skillsFallback: Bool = SlashCatalog.fallsBackToWorkspaceSkills,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.connection = connection
        self.workspace = workspace
        self.subagentsModel = subagents
        self.skillsFallback = skillsFallback
        self.now = now
    }

    /// Skills de la session (`sessionId`) ou du projet (`nil`) ; `nil` si jamais lues ou en échec.
    public func skills(sessionId: String?) -> [SlashEntry]? {
        skillsByAuthority[sessionId ?? ""]?.entries
    }

    public func sections(query: String, sessionId: String?) -> [SlashSection] {
        SlashSuggestions.sections(commands: commands, skills: skills(sessionId: sessionId), subagents: subagents, query: query)
    }

    /// Relit ce qui a plus de 5 minutes ou n'a pas pu être lu. Pendant une lecture en cours, attend sa fin puis réévalue
    /// pour son propre `sessionId` (l'autorité a pu changer entre-temps).
    public func refreshIfNeeded(sessionId: String?) async {
        await waitForRead()
        let workspaceStale = isStale(workspaceLoadedAt) || commands == nil || subagents == nil
        let cached = skillsByAuthority[sessionId ?? ""]
        let skillsStale = isStale(cached?.at) || cached?.entries == nil
        guard workspaceStale || skillsStale else { return }
        await run(sessionId: sessionId, workspaceToo: workspaceStale)
    }

    public func refresh(sessionId: String?) async {
        await waitForRead()
        await run(sessionId: sessionId, workspaceToo: true)
    }

    /// Attend la lecture en cours, s'il y en a une (une annulation de l'appelant n'interrompt pas l'attente utile).
    private func waitForRead() async {
        while let task = inflight { await task.value }
    }

    /// La lecture tourne dans une tâche tenue par le catalogue : l'annulation de l'appelant (`.task(id:)` d'une vue qui
    /// change d'autorité ou disparaît) ne l'interrompt pas, sinon les sources lues par `try?` resteraient vides.
    private func run(sessionId: String?, workspaceToo: Bool) async {
        let task = Task {
            defer { self.inflight = nil }
            await self.load(sessionId: sessionId, workspaceToo: workspaceToo)
        }
        inflight = task
        await task.value
    }

    private func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return now().timeIntervalSince(date) > Self.maxAge
    }

    private func load(sessionId: String?, workspaceToo: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let key = sessionId ?? ""
        guard let channel = await connection.ensureConnected() else {
            if workspaceToo { commands = nil }
            skillsByAuthority[key] = CachedSkills(entries: nil, at: now())
            return
        }
        let client = ComposerCatalogClient(client: channel, workspacePath: workspace)
        let fallback = skillsFallback                       // lu ici : les tâches filles ne touchent pas à l'acteur principal
        async let presentation = Self.presentation(client, wanted: workspaceToo)
        async let catalog = Self.skillCatalog(client, sessionId: sessionId, fallback: fallback)
        if workspaceToo { await subagentsModel.loadIfNeeded() }
        let readPresentation = await presentation
        let readCatalog = await catalog
        let at = now()
        if workspaceToo {
            commands = readPresentation.map { SlashSuggestions.commands($0.slashCommands) }
            subagents = subagentsModel.list.map { SlashSuggestions.subagents($0.agents) }
            workspaceLoadedAt = at
        }
        skillsByAuthority[key] = CachedSkills(entries: readCatalog.map { SlashSuggestions.skills($0.skills) }, at: at)
    }

    nonisolated private static func presentation(_ client: ComposerCatalogClient, wanted: Bool) async -> WorkspacePresentation? {
        guard wanted else { return nil }
        return try? await client.presentation()
    }

    nonisolated private static func skillCatalog(_ client: ComposerCatalogClient, sessionId: String?,
                                                 fallback: Bool) async -> SkillReferenceCatalog? {
        if let catalog = try? await client.skills(sessionId: sessionId) { return catalog }
        guard fallback, sessionId != nil else { return nil }
        return try? await client.skills(sessionId: nil)
    }
}
