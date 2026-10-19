import Foundation
import Observation
import ZCodeClient
import ZCodeV4
import ZCodeWire

public enum LaunchOutcome: Equatable, Sendable {
    case started(sessionId: String, runId: String?)
    case failed(message: String, detail: String?)
}

/// Workflows enregistrés d'un projet (liste du projet et liste globale, lues ensemble) et lancement dans une session
/// neuve. L'entrée « Workflows » n'existe que si la barrière de l'hôte est ouverte (`available`).
@MainActor
@Observable
public final class SavedWorkflowsModel {
    public enum Phase: Equatable, Sendable { case idle, loading, ready, failed(String) }

    public let workspace: String
    public private(set) var phase: Phase = .idle
    /// `nil` tant que non lu ; faux ⇒ entrée « Workflows » masquée.
    public private(set) var available: Bool?
    public private(set) var project: SavedWorkflowList?
    public private(set) var global: SavedWorkflowList?
    /// Une section en échec n'empêche pas l'autre (message par section).
    public private(set) var projectError: String?
    public private(set) var globalError: String?
    public private(set) var launching = false
    @ObservationIgnored private var availabilityKnown = false
    private let connection: HostConnection
    private let sessions: SessionsModel
    private let builder: CommandBuilder

    public init(connection: HostConnection, workspace: String, sessions: SessionsModel, builder: CommandBuilder) {
        self.connection = connection
        self.workspace = workspace
        self.sessions = sessions
        self.builder = builder
    }

    /// Lit la barrière une fois par instance ; une panne de connexion ou d'appel laisse relire plus tard. Une réponse
    /// illisible vaut « fermée ».
    public func checkAvailability() async {
        guard !availabilityKnown else { return }
        guard let channel = await connection.ensureConnected() else { return }
        let client = ComposerCatalogClient(client: channel, workspacePath: workspace)
        do {
            available = try await client.dynamicWorkflowConfig().enabled
            availabilityKnown = true
        } catch AgentV4Error.malformedResponse {
            available = false
            availabilityKnown = true
        } catch {
            available = false
        }
    }

    /// Deux lectures en parallèle ; la phase n'est en échec que si les deux le sont.
    public func refresh() async {
        phase = .loading
        guard let channel = await connection.ensureConnected() else {
            let message = connection.failure?.message ?? "Hôte injoignable."
            projectError = message
            globalError = message
            phase = .failed(message)
            return
        }
        let client = SavedWorkflowsClient(client: channel, workspacePath: workspace)
        async let projectRead = Self.readProject(client)
        async let globalRead = Self.readGlobal(client)
        let (projectResult, globalResult) = await (projectRead, globalRead)
        switch projectResult {
        case .success(let list): project = list; projectError = nil
        case .failure(let error): projectError = WorkflowLabels.listFailure(error)
        }
        switch globalResult {
        case .success(let list): global = list; globalError = nil
        case .failure(let error): globalError = WorkflowLabels.listFailure(error)
        }
        if let projectError, let globalError, project == nil, global == nil {
            phase = .failed(projectError == globalError ? projectError : "\(projectError) \(globalError)")
        } else {
            phase = .ready
        }
    }

    /// Session ouverte en cas de succès ; sinon la session vide créée pour l'occasion est supprimée.
    public func launch(_ workflow: SavedWorkflow, args: [String: JSONValue]?) async -> LaunchOutcome {
        guard !launching else { return .failed(message: WorkflowLabels.launchInProgress, detail: nil) }
        launching = true
        defer { launching = false }
        let sessionId: String
        do {
            sessionId = try await sessions.createSession(builder: builder)
        } catch {
            return .failed(message: WorkflowLabels.launchFailed, detail: error.localizedDescription)
        }
        do {
            guard let agent = await connection.agent(workspace: workspace) else {
                throw SessionsError.notConnected(connection.failure?.message ?? "Hôte injoignable.")
            }
            let ack = try await agent.send(builder.startSavedWorkflow(
                sessionId: sessionId, name: workflow.name, scope: workflow.scope, args: args))
            if ack.isAccepted {
                return .started(sessionId: sessionId, runId: ack.result?.raw["runId"]?.stringValue)
            }
            await discard(sessionId)
            return .failed(message: WorkflowLabels.startRefusal(reasonCode: ack.reasonCode, status: ack.status.rawValue),
                           detail: ack.message)
        } catch {
            await discard(sessionId)
            return .failed(message: WorkflowLabels.launchFailed, detail: error.localizedDescription)
        }
    }

    /// Supprime la session vide sur l'hôte ; même si l'hôte refuse, le brouillon local est retiré (pas de session fantôme).
    private func discard(_ sessionId: String) async {
        try? await sessions.deleteSession(sessionId, builder: builder)
        sessions.discardDraft(sessionId)
    }

    nonisolated private static func readProject(_ client: SavedWorkflowsClient) async -> Result<SavedWorkflowList, Error> {
        do { return .success(try await client.project()) } catch { return .failure(error) }
    }

    nonisolated private static func readGlobal(_ client: SavedWorkflowsClient) async -> Result<SavedWorkflowList, Error> {
        do { return .success(try await client.global()) } catch { return .failure(error) }
    }
}
