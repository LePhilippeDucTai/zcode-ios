import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Sous-agents d'un hôte pour une portée (Utilisateur ou un projet), lus et modifiés par le canal `subagents`. Une
/// lecture à la demande, sans écoute : le canal n'a aucun événement. La liste lue reste affichée si une relecture échoue
/// (hors ligne, lecture seule) ; l'hôte relit les fichiers d'agents au début de chaque tour, sans redémarrage.
@MainActor
@Observable
public final class SubagentsModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var list: AgentsListResult?
    /// Une action est en cours : les autres sont ignorées.
    public private(set) var busy = false
    /// Échec de la dernière action (refus du client ou de l'hôte).
    public private(set) var actionError: String?
    /// Avis après une action réussie (prise en compte différée).
    public private(set) var notice: String?
    /// La dernière lecture a échoué faute de connexion (et non par un refus de l'hôte) : bandeau « Hors ligne ».
    public private(set) var isOffline = false
    public let scope: ExtensionScope

    private let connection: HostConnection
    @ObservationIgnored private var generation = 0
    /// Agents renommés par `save` : ancien (identifiant, chemin) -> nouveau. Un écran ouvert sur l'ancien agent suit le
    /// nouveau au lieu de garder l'instantané périmé.
    private var successors: [AgentKey: AgentKey] = [:]

    private struct AgentKey: Hashable {
        let id: String
        let path: String
    }

    public init(connection: HostConnection, scope: ExtensionScope) {
        self.connection = connection
        self.scope = scope
    }

    /// Hors ligne, en cours de lecture ou jamais lu : aucune modification possible.
    public var isReadOnly: Bool { phase != .ready }

    /// En portée Utilisateur, l'hôte n'offre pas les sous-agents de l'utilisateur (`capability.userScopeAvailable`) : le
    /// motif à afficher ; `nil` sinon (portée Projet, ou liste pas encore lue).
    public var userScopeUnavailable: String? {
        guard scope == .user, let list, !list.userScopeAvailable else { return nil }
        return ExtensionsLabels.userScopeUnavailable(reason: list.userScopeReason)
    }

    /// « Nouveau sous-agent » possible : liste lue, aucune action en cours, portée offerte par l'hôte (comme ZCode Web).
    public var canCreate: Bool { !isReadOnly && !busy && userScopeUnavailable == nil }

    public func sections(query: String) -> [SubagentSection] {
        guard let list else { return [] }
        return SubagentSections.make(list, scope: scope, query: query)
    }

    /// Version la plus récente d'un agent de la liste lue (les écrans ouverts sur un agent suivent les relectures). Le
    /// chemin du fichier est exigé en plus de l'identifiant : `user:workspace:<nom>` ne porte pas le projet, deux projets
    /// peuvent avoir un agent de même nom, et une suppression ne doit jamais viser le fichier de l'autre.
    /// Un agent renommé par `save` est suivi sous son nouveau nom, mais seulement tant que l'ancien (identifiant, chemin)
    /// n'est plus dans la liste lue : si un nouvel agent reprend ce nom, c'est lui que l'on trouve. Si le successeur n'est
    /// plus dans la liste non plus, rien n'est trouvé.
    public func agent(id: String, path: String) -> AgentSummary? {
        guard let list else { return nil }
        let all = list.userAgents + list.pluginAgents + list.agents
        func find(_ key: AgentKey) -> AgentSummary? { all.first { $0.id == key.id && $0.path == key.path } }
        var key = AgentKey(id: id, path: path)
        if let direct = find(key) { return direct }
        var seen: Set<AgentKey> = [key]
        var found: AgentSummary?
        while let next = successors[key], seen.insert(next).inserted {
            key = next
            if let renamed = find(next) { found = renamed }
        }
        return found
    }

    /// Agents modifiables de la portée (la section « Personnalisés » de la liste), sans filtre de recherche.
    public var customAgents: [AgentSummary] {
        sections(query: "").first { $0.kind == .custom }?.agents ?? []
    }

    // MARK: - Lecture

    /// À chaque apparition de la liste : première lecture, nouvel essai après un échec, ou relecture **silencieuse** d'une
    /// liste déjà lue (un plugin installé ailleurs apporte des sous-agents, ZCode Web peut en modifier). La relecture
    /// silencieuse garde la liste affichée, l'avis et l'erreur, sans passage visible en `.loading` ; aucune relecture
    /// pendant une action (elle se termine par la sienne) ni pendant une lecture en vol.
    public func loadIfNeeded() async {
        // Les messages ne s'effacent qu'à la première lecture : au retour du détail (suppression, modèle imposé), la liste
        // se réaffiche et l'avis de prise en compte différée doit rester visible.
        if phase == .idle, !busy { dismissMessages() }
        switch phase {
        case .idle, .failed: await reload(announcing: true)
        case .ready:
            guard !busy else { return }
            // Tâche détachée de l'appelant : `.task` est annulé quand l'écran disparaît (détail poussé, autre rubrique),
            // et une relecture annulée afficherait une erreur à la place de la liste.
            await Task { await self.reload(announcing: false) }.value
        case .loading: return
        }
    }

    /// Relit la liste ; un appel en vol est abandonné au profit du plus récent.
    public func refresh() async {
        if !busy { dismissMessages() }
        await reload(announcing: true)
    }

    private func reload(announcing: Bool) async {
        generation += 1
        let generation = self.generation
        if announcing { phase = .loading }
        do {
            let client = try await makeClient()
            let result = try await client.list(scope: scope)
            guard generation == self.generation else { return }
            list = result
            isOffline = false
            phase = .ready
            purgeSuccessors(in: result)
        } catch {
            guard generation == self.generation else { return }
            isOffline = ExtensionsHost.isOffline(error)
            phase = .failed("Sous-agents indisponibles : \(Self.message(error))")
        }
    }

    /// Un ancien nom qui réapparaît (nouvel agent de même nom) n'est plus un renommage à suivre.
    private func purgeSuccessors(in list: AgentsListResult) {
        guard !successors.isEmpty else { return }
        let present = Set((list.userAgents + list.pluginAgents + list.agents).map { AgentKey(id: $0.id, path: $0.path) })
        successors = successors.filter { !present.contains($0.key) }
    }

    // MARK: - Actions

    public func setEnabled(_ agent: AgentSummary, _ enabled: Bool) async {
        await perform { client in try await client.setEnabled(agent, enabled) }
    }

    public func delete(_ agent: AgentSummary) async {
        await perform { client in try await client.delete(agent) }
    }

    /// Modèle imposé à un agent intégré ou de plugin ; `nil` rétablit le défaut.
    public func setModelOverride(_ agent: AgentSummary, _ selection: ModelSelection?) async {
        await perform { client in try await client.setModelOverride(agent, selection) }
    }

    /// Crée (`editing == nil`) ou modifie un sous-agent, puis relit la liste ; `true` si l'hôte l'a enregistré. Un
    /// formulaire invalide n'appelle pas l'hôte : `actionError` porte le premier défaut. Le modèle et l'effort ne sont
    /// contrôlés que par la vue, qui connaît le catalogue.
    public func save(_ form: SubagentForm, editing agent: AgentSummary?) async -> Bool {
        guard !busy, phase == .ready else { return false }
        if agent == nil, let unavailable = userScopeUnavailable {
            dismissMessages()
            actionError = unavailable
            return false
        }
        if let first = form.issues(existing: customAgents, editing: agent, catalog: nil).first {
            dismissMessages()
            actionError = first.message
            return false
        }
        let config = form.config(basedOn: agent)
        let saved = await performReturning { [scope] client -> AgentSummary in
            guard let agent else { return try await client.create(config, scope: scope) }
            guard let agentScope = Self.scope(of: agent, within: scope) else { throw SubagentsClientError.readOnly(agent.name) }
            return try await client.update(agent, with: config, scope: agentScope)
        }
        guard let saved else { return false }
        if let agent, (agent.id, agent.path) != (saved.id, saved.path) {
            successors[AgentKey(id: agent.id, path: agent.path)] = AgentKey(id: saved.id, path: saved.path)
        }
        return true
    }

    /// Portée d'écriture d'un agent lu : celle de l'agent, jamais celle qu'on affiche (le client ne vérifie pas que les
    /// deux concordent).
    nonisolated private static func scope(of agent: AgentSummary, within scope: ExtensionScope) -> ExtensionScope? {
        switch agent.scope {
        case .user: .user
        case .workspace:
            (agent.projectPath ?? scope.workspacePath).map(ExtensionScope.workspace)
        default: nil
        }
    }

    public func dismissMessages() {
        actionError = nil
        notice = nil
    }

    /// Une mutation à la fois, hors ligne comprise : refusée. La liste est relue après une mutation réussie ou refusée
    /// par l'hôte (le `enabled` qu'il renvoie n'est pas fiable) ; un refus du client ne fait aucun appel, donc aucune
    /// relecture.
    private func perform(_ action: @Sendable (SubagentsClient) async throws -> Void) async {
        _ = await performReturning { client -> Void in try await action(client) }
    }

    /// Variante qui rend le résultat de l'action (`nil` si elle a échoué ou été refusée).
    private func performReturning<Result: Sendable>(_ action: @Sendable (SubagentsClient) async throws -> Result) async -> Result? {
        guard !busy, phase == .ready else { return nil }
        busy = true
        defer { busy = false }
        actionError = nil
        notice = nil
        var result: Result?
        do {
            let client = try await makeClient()
            result = try await action(client)
            notice = ExtensionsLabels.subagentsTakeEffect
        } catch let refusal as SubagentsClientError {
            actionError = ExtensionsLabels.subagentFailure(refusal)
            return nil
        } catch {
            actionError = Self.message(error)
        }
        await reload(announcing: false)
        return result
    }

    // MARK: - Connexion

    /// Le canal exige un projet de l'hôte (voir `ExtensionsHost`).
    private func makeClient() async throws -> SubagentsClient {
        let (channel, workspace) = try await ExtensionsHost.channelAndWorkspace(connection: connection, scope: scope)
        return SubagentsClient(client: channel, hostWorkspace: workspace)
    }

    private static func message(_ error: any Error) -> String {
        ExtensionsHost.message(error, otherwise: ExtensionsLabels.subagentFailure)
    }
}
