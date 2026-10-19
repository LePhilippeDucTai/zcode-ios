import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Résultats des étapes de `zcode-probe check`, affichés au fil de l'eau.
struct CheckReport {
    enum Outcome: Equatable {
        case passed
        case warning(String)
        case failed(String)
    }

    struct Entry: Equatable {
        let name: String
        let outcome: Outcome
        let duration: Duration
    }

    private(set) var entries: [Entry] = []

    var succeeded: Bool {
        !entries.isEmpty && !entries.contains { if case .failed = $0.outcome { true } else { false } }
    }

    mutating func record(_ name: String, _ outcome: Outcome, duration: Duration = .zero) {
        let entry = Entry(name: name, outcome: outcome, duration: duration)
        entries.append(entry)
        print(Self.line(for: entry))
    }

    static func line(for entry: Entry) -> String {
        let seconds = Double(entry.duration.components.seconds) + Double(entry.duration.components.attoseconds) / 1e18
        let time = entry.duration == .zero ? "" : String(format: " (%.1f s)", seconds)
        switch entry.outcome {
        case .passed: return "✓ \(entry.name)\(time)"
        case .warning(let reason): return "⚠ \(entry.name) : \(reason)"
        case .failed(let reason): return "✗ \(entry.name)\(time) : \(reason)"
        }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Exécute une étape d'une sonde, l'inscrit au rapport (durée, motif d'échec) et rend sa valeur, ou `nil` en cas
/// d'échec : l'appelant décide de continuer ou non.
@discardableResult
func runStep<T>(_ name: String, _ report: inout CheckReport, _ body: () async throws -> T) async -> T? {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let value = try await body()
        report.record(name, .passed, duration: clock.now - start)
        return value
    } catch {
        report.record(name, .failed(describeProbeError(error)), duration: clock.now - start)
        return nil
    }
}

/// Motif lisible d'un échec : message de l'hôte, constat de la sonde, sinon l'erreur brute.
func describeProbeError(_ error: any Error) -> String {
    switch error {
    case RPCError.remote(let remote): remote.message
    case let failure as CheckFailure: failure.description
    default: String(describing: error)
    }
}

/// Projection courante d'un abonnement, ou erreur s'il a échoué.
func feedValue<P: TopicProjection>(of feed: TopicFeed<P>) async throws -> P? {
    if let failure = await feed.failure { throw CheckFailure(failure) }
    return await feed.current
}

/// En-tête du tour lancé par la commande `commandId`.
func turnHeader(in snapshot: ConversationSnapshot, for commandId: String) -> ConversationRow? {
    snapshot.rows.last { $0.kind == .turnHeader && $0.raw["sourceCommandId"]?.stringValue == commandId }
}

/// Accorde une demande d'autorisation **une fois** (`allowOnce`) : jamais une autorisation durable ; une demande sans
/// cette option, une interaction d'un autre type ou un refus de l'hôte font échouer l'étape.
func approveOnce(_ interaction: PendingInteraction, sessionId: String, agent: AgentV4, builder: CommandBuilder) async throws {
    guard case .permission(let request) = interaction.payload else {
        throw CheckFailure("interaction inattendue : \(interaction.kind)")
    }
    guard let option = request.options.first(where: { $0.kind == .allowOnce }) else {
        throw CheckFailure("aucune option allowOnce (\(request.options.map(\.kind.rawValue)))")
    }
    let ack = try await agent.send(builder.resolveInteraction(
        sessionId: sessionId, interactionId: interaction.interactionId, answer: InteractionAnswer(optionId: option.optionId)))
    guard ack.isAccepted else { throw CheckFailure("approbation refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
}

/// Sonde jusqu'à obtenir une valeur ou dépasser le délai.
func poll<T>(within timeout: Duration, every interval: Duration = .milliseconds(250), _ probe: () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        if let value = try await probe() { return value }
        guard ContinuousClock.now < deadline else { throw CheckFailure("délai de \(timeout) dépassé") }
        try await Task.sleep(for: interval)
    }
}

extension HostEndpoint {
    /// Serveur sur cette machine : le fichier écrit par l'agent peut être vérifié et supprimé directement.
    var isLocalHost: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL.host() ?? "") }
}

/// Test de contrat de bout en bout contre un serveur ZCode réel.
struct ContractCheck {
    static let clientId = "client-zcode-probe-check"

    let endpoint: HostEndpoint
    let workspace: String
    var turnTimeout: Duration = .seconds(240)

    private struct Resources {
        var index: TopicFeed<SessionsIndex>?
        var conversation: TopicFeed<ConversationSnapshot>?
        var sessionId: String?
        var scratchFile: URL?
    }

    func run() async -> CheckReport {
        var report = CheckReport()
        if let info = await runStep("server-info", &report, { try await ServerInfo.fetch(from: endpoint) }),
           info.version != V4Protocol.lastTestedServerVersion {
            report.record("version de ZCode", .warning(
                "\(info.version) (dernière version testée : \(V4Protocol.lastTestedServerVersion))"))
        }
        guard let client = await runStep("connexion WebSocket", &report, { try await ZCodeConnector.connect(to: endpoint) }) else {
            return report
        }
        let agent = AgentV4(client: client, workspacePath: workspace)
        if await runStep("handshake V4", &report, { try await agent.handshake(clientId: Self.clientId, appVersion: "zcode-probe") }) != nil {
            var resources = Resources()
            await exercise(agent, &report, &resources)
            await cleanUp(agent, &report, resources)
        }
        await client.close()
        return report
    }

    // MARK: - Étapes

    private func exercise(_ agent: AgentV4, _ report: inout CheckReport, _ resources: inout Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        let index = TopicFeed<SessionsIndex>(topic: Topic.sessionsIndex(workspace), operations: agent.sessionsIndexOperations())
        resources.index = index
        guard await runStep("index des sessions", &report, { () async throws -> Void in
            try await index.start(frames: agent.sessionsIndexFrames())
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: index) }
        }) != nil else { return }

        let create = builder.createSession(workspaceId: workspace)
        guard let sessionId = await runStep("création d'une session", &report, { () async throws -> String in
            let ack = try await agent.send(create)
            guard ack.isAccepted, let sessionId = ack.result?.sessionId else {
                throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
            }
            return sessionId
        }) else { return }
        resources.sessionId = sessionId

        let conversation = TopicFeed<ConversationSnapshot>(
            topic: Topic.conversation(sessionId), operations: agent.conversationOperations(sessionId: sessionId))
        resources.conversation = conversation
        guard await runStep("abonnement à la conversation", &report, { () async throws -> Void in
            try await conversation.start(frames: agent.conversationFrames())
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: conversation) }
        }) != nil else { return }

        let fileName = ".zcode-check/\(create.commandId).txt"
        if endpoint.isLocalHost {
            let directory = URL(filePath: workspace).appending(path: ".zcode-check")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resources.scratchFile = directory.appending(path: "\(create.commandId).txt")
        }
        let send = builder.sendText(
            sessionId: sessionId,
            text: "Crée le fichier \(fileName) avec pour seul contenu le texte « contrat OK » "
                + "(sans les guillemets ni point final). Utilise ton outil d'écriture de fichiers, puis confirme en une phrase.")
        guard await runStep("envoi du prompt", &report, { () async throws -> Void in
            let ack = try await agent.send(send)
            guard ack.isAccepted else { throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil else { return }
        // Une session vide n'est publiée dans l'index qu'à son premier message (vérifié sur ZCode 3.15.1).
        await runStep("session visible dans l'index", &report) {
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: index)?.session(id: sessionId) }
        }

        // En mode build, ZCode demande l'autorisation d'écrire : chaque demande est accordée une fois.
        var answered: Set<String> = []
        var shapeIssues: [String] = []
        let finished = await runStep("tour terminé", &report) { () async throws -> (ConversationSnapshot, ConversationRow) in
            try await poll(within: turnTimeout, every: .milliseconds(500)) { () async throws -> (ConversationSnapshot, ConversationRow)? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                if let interaction = snapshot.pendingInteractions.first(where: { !answered.contains($0.interactionId) }) {
                    shapeIssues += Self.shapeIssues(of: interaction)
                    try await approveOnce(interaction, sessionId: sessionId, agent: agent, builder: builder)
                    answered.insert(interaction.interactionId)
                    return nil
                }
                guard let header = turnHeader(in: snapshot, for: send.commandId),
                      case .turnHeader(let turn) = header.content, turn.state != .running else { return nil }
                guard turn.state == .completedSuccess else {
                    throw CheckFailure("tour terminé en \(turn.state) (\(snapshot.control?.lastError?.message ?? "sans erreur"))")
                }
                return (snapshot, header)
            }
        }
        report.record("approbation", answered.isEmpty
            ? .warning("aucune demande d'approbation : chemin non exercé")
            : .passed)
        report.record("forme de la demande d'approbation", answered.isEmpty
            ? .warning("non exercée")
            : shapeIssues.isEmpty ? .passed : .warning(shapeIssues.joined(separator: " ; ")))
        guard let finished else { return }
        let (snapshot, header) = finished

        await runStep("appel d'outil réussi", &report) {
            let calls = snapshot.rows.filter { $0.turnId == header.turnId }.compactMap { row -> ToolCall? in
                if case .toolCall(let call) = row.content { call } else { nil }
            }
            guard calls.contains(where: { $0.status == .success }) else {
                throw CheckFailure("aucun appel d'outil réussi (\(calls.map { "\($0.toolName) : \($0.status)" }))")
            }
        }
        if let scratch = resources.scratchFile {
            await runStep("fichier écrit sur l'hôte", &report) {
                let content = try String(contentsOf: scratch, encoding: .utf8)
                guard content.trimmingCharacters(in: .whitespacesAndNewlines) == "contrat OK" else {
                    throw CheckFailure("contenu inattendu : \(content.prefix(80))")
                }
            }
        }
        let changedPath = await runStep("changements de fichiers du tour", &report) { () async throws -> String in
            // Résumé côté serveur d'abord (aucune cible en jeu) : un échec du RPC qui suit vient alors de ses paramètres.
            guard case .turnHeader(let turn) = header.content, (turn.fileChanges?.files ?? 0) >= 1 else {
                throw CheckFailure("l'en-tête du tour ne signale aucun fichier modifié")
            }
            // Même cible que l'interface web (`ConversationFileSummaryPanel.tsx`) : l'en-tête de tour.
            guard let target = RowTarget(row: header) else { throw CheckFailure("en-tête de tour sans entityId") }
            let changes = try await agent.fileChanges(sessionId: sessionId, target: target, base: snapshot.commandBase)
            guard let item = changes.items.first(where: { $0.path.hasSuffix(fileName) }) else {
                throw CheckFailure("fichier absent du diff : \(changes.items.map(\.path))")
            }
            return item.path
        }
        if let changedPath {
            await checkWorkspaceChannels(agent, changedPath: changedPath, &report)
        }
        await runStep("historique (rowsRange)", &report) {
            let page = try await agent.rowsRange(sessionId: sessionId)
            guard page.atLogEpoch == snapshot.logEpoch, page.rows.count >= 3 else {
                throw CheckFailure("page inattendue : \(page.rows.count) lignes, époque \(page.atLogEpoch)")
            }
        }
    }

    /// Canaux `file` et `git` sur le fichier écrit par l'agent : lecture seule, aucun prompt de plus ; vaut aussi via le
    /// tailnet (c'est l'hôte qui lit).
    private func checkWorkspaceChannels(_ agent: AgentV4, changedPath: String, _ report: inout CheckReport) async {
        let files = FileClient(client: agent.client)
        await runStep("lecture du fichier (file.readTextFile)", &report) {
            let slice = try await files.readTextFile(path: changedPath)
            guard !slice.isBinary, slice.content.trimmingCharacters(in: .whitespacesAndNewlines) == "contrat OK" else {
                throw CheckFailure("contenu inattendu : \(slice.content.prefix(80))")
            }
        }
        await runStep("dossier du fichier (file.readdir)", &report) {
            let directory = (changedPath as NSString).deletingLastPathComponent
            let name = (changedPath as NSString).lastPathComponent
            let entries = try await files.readdir(path: directory, includeHidden: true)
            guard entries.contains(where: { $0.name == name && !$0.isDirectory }) else {
                throw CheckFailure("\(name) absent de \(entries.map(\.name))")
            }
        }
        await runStep("état Git du projet (git.refresh)", &report) {
            // L'espace de travail peut ne pas être un dépôt : la réponse doit seulement se décoder (`isRepository == false`).
            _ = try await GitClient(client: agent.client, workspacePath: workspace).refresh()
        }
    }

    /// Toujours exécuté : supprime la session et le fichier de test, ferme les abonnements.
    private func cleanUp(_ agent: AgentV4, _ report: inout CheckReport, _ resources: Resources) async {
        await resources.conversation?.stop()
        if let sessionId = resources.sessionId {
            await runStep("suppression de la session", &report) {
                let ack = try await agent.send(CommandBuilder(clientId: Self.clientId).deleteSession(sessionId: sessionId))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
                if let index = resources.index {
                    _ = try await poll(within: .seconds(15)) { () async throws -> Bool? in
                        guard let current = try await feedValue(of: index) else { return nil }
                        return current.session(id: sessionId) == nil ? true : nil
                    }
                }
            }
        }
        await resources.index?.stop()
        if let scratch = resources.scratchFile {
            try? FileManager.default.removeItem(at: scratch)
            let directory = scratch.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    // MARK: - Outils

    /// Écarts entre une demande réelle et ce que l'app attend (dérive du format de ZCode : à examiner, pas bloquant).
    static func shapeIssues(of interaction: PendingInteraction) -> [String] {
        guard case .permission(let request) = interaction.payload else { return ["type \(interaction.kind.rawValue)"] }
        var issues: [String] = []
        if interaction.createdAt == nil { issues.append("createdAt absent") }
        if request.detail == nil { issues.append("detail absent") }
        let kinds = Set(request.options.map(\.kind))
        if !kinds.contains(.allowOnce) { issues.append("pas d'option allowOnce") }
        if !kinds.contains(.deny) { issues.append("pas d'option deny") }
        return issues
    }
}
