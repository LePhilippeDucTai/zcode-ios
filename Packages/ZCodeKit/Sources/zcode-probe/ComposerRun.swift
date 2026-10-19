import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// `zcode-probe composer` : contrat réel du lot 13C dans un projet jetable (`--workspace` sous `.zcode-check`).
/// Toujours, sans prompt : session neuve (`createSession` simple, comme l'app) → catalogue des skills de cette session
/// vide → présentation du projet. `--fork` (un prompt GLM) : « PONG » → catalogue après le tour → `forkAssistant` sur
/// une base périmée, sur le message, puis sur la réponse → premier état de la session enfant. `--workflow` (un prompt
/// GLM et un petit run) : `/workflow …` → demandes enregistrées (autorisations accordées une fois) → run vu dans
/// `backgroundWorks` → `cancelBackgroundWork` → tour arrêté. Les sessions sont supprimées à la fin, enfants d'abord.
/// L'ordre des enregistrements (`--record`) est celui que décrit la tâche 0 du plan 13C.
struct ComposerRun {
    static let clientId = "client-zcode-probe-composer"
    static let pong = "Réponds uniquement par le mot PONG, sans rien d'autre."
    static let workflowPrompt = "/workflow Un workflow minimal : une seule phase, un seul agent qui répond OK, sans lire ni écrire de fichier."
    /// Autorisations accordées au plus pendant `--workflow` ; le run est annulé dès qu'il apparaît.
    static let maxApprovals = 4

    let endpoint: HostEndpoint
    let workspace: String
    let scenario: ProbeOptions.ComposerScenario
    let output: ProbeOutput
    var turnTimeout: Duration = .seconds(180)

    private struct Resources {
        /// Sessions créées, dans l'ordre : supprimées à rebours (enfants d'abord).
        var sessions: [String] = []
        var feeds: [(sessionId: String, feed: TopicFeed<ConversationSnapshot>)] = []
    }

    func run() async -> CheckReport {
        var report = CheckReport()
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

    private func exercise(_ agent: AgentV4, _ report: inout CheckReport, _ resources: inout Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        guard let sessionId = await runStep("création d'une session (createSession simple, comme l'app)", &report, { () async throws -> String in
            let ack = try await agent.send(builder.createSession(workspaceId: workspace))
            await emit("createSession", Self.summary(ack))
            guard ack.isAccepted, let sessionId = ack.result?.sessionId else {
                throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
            }
            return sessionId
        }) else { return }
        resources.sessions.append(sessionId)
        guard let conversation = await runStep("abonnement à la conversation", &report, {
            try await subscribe(agent, sessionId)
        }) else { return }
        resources.feeds.append((sessionId, conversation))
        await recordCall(agent.client, "zcode-agent", "getSkillReferenceCatalog",
                         ["workspacePath": .string(workspace), "sessionId": .string(sessionId)])
        await recordCall(agent.client, "zcode-session", "readWorkspacePresentation", ["workspacePath": .string(workspace)])
        switch scenario {
        case .quiet:
            break
        case .fork:
            await fork(agent, builder, sessionId, conversation, &report, &resources)
        case .workflow:
            await workflow(agent, builder, sessionId, conversation, &report)
        }
    }

    // MARK: - Repartir d'ici

    private func fork(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                      _ conversation: TopicFeed<ConversationSnapshot>, _ report: inout CheckReport,
                      _ resources: inout Resources) async {
        guard await runStep("prompt PONG (un prompt GLM)", &report, { () async throws -> Void in
            let ack = try await agent.send(builder.sendText(sessionId: sessionId, text: Self.pong, mode: "build"))
            await emit("pong.ack", Self.summary(ack))
            guard ack.isAccepted else { throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil else { return }
        guard let answered = await runStep("réponse figée avec actions.canFork", &report, { () async throws -> ConversationSnapshot in
            try await poll(within: turnTimeout, every: .milliseconds(500)) { () async throws -> ConversationSnapshot? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                if let interaction = snapshot.pendingInteractions.first {
                    throw CheckFailure("demande inattendue : \(interaction.kind)")
                }
                guard snapshot.control?.canStop != true,
                      snapshot.rows.contains(where: { $0.kind == .assistantText && $0.actions.canFork }) else { return nil }
                return snapshot
            }
        }) else { return }
        guard let answer = answered.rows.last(where: { $0.kind == .assistantText && $0.actions.canFork }),
              let target = RowTarget(row: answer) else {
            report.record("cible du fork", .failed("réponse sans entityId"))
            return
        }
        await emit("assistantRow", answer.json)
        await recordCall(agent.client, "zcode-agent", "getSkillReferenceCatalog",
                         ["workspacePath": .string(workspace), "sessionId": .string(sessionId)])
        // Formes de refus d'abord (aucun prompt) : base périmée, puis le message de l'utilisateur comme cible.
        let staleBase = CommandBase(revision: max(answered.revision - 1, 0), logEpoch: answered.logEpoch)
        await attemptFork(agent, builder, sessionId, target, staleBase, name: "forkAssistant.stale", &resources)
        if let message = answered.rows.last(where: { $0.kind == .userInput }).flatMap(RowTarget.init(row:)),
           let current = await conversation.current {
            await attemptFork(agent, builder, sessionId, message, current.commandBase, name: "forkAssistant.userInput", &resources)
        } else {
            await emit("forkAssistant.userInput", .null)
        }
        guard let current = await conversation.current else { return }
        let ack = await attemptFork(agent, builder, sessionId, target, current.commandBase, name: "forkAssistant", &resources)
        guard let ack, ack.isAccepted, let child = ack.result?.sessionId else {
            report.record("forkAssistant sur la réponse", .failed(ack.map { "\($0.status) \($0.reasonCode ?? "")" } ?? "erreur de l'hôte"))
            return
        }
        report.record("forkAssistant sur la réponse", .passed)
        guard let childFeed = await runStep("abonnement à la session enfant", &report, {
            try await subscribe(agent, child)
        }) else { return }
        resources.feeds.append((child, childFeed))
        guard let snapshot = await childFeed.current else { return }
        await emit("child.state", .object([
            "sessionId": .string(snapshot.sessionId), "config": snapshot.state["config"] ?? .null,
            "meta": snapshot.state["meta"] ?? .null, "totalCount": .number(Double(snapshot.totalCount)),
        ]))
        await emit("child.rows", .array(snapshot.rows.prefix(4).map(\.json)))
        let notice = snapshot.rows.contains { $0.raw["marker"]?["type"]?.stringValue == "forkNotice" }
        report.record("ligne forkNotice dans l'enfant", notice ? .passed : .warning("absente des premières lignes"))
    }

    /// Envoie `forkAssistant` et enregistre l'accusé sous `name` ; une session enfant créée est gardée pour le ménage.
    @discardableResult
    private func attemptFork(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String, _ target: RowTarget,
                             _ base: CommandBase, name: String, _ resources: inout Resources) async -> CommandAck? {
        do {
            let envelope = try builder.envelope(.forkAssistant, sessionId: sessionId, payload: ["target": target.json], base: base)
            let ack = try await agent.send(envelope)
            await emit(name, Self.summary(ack))
            if ack.isAccepted, let child = ack.result?.sessionId { resources.sessions.append(child) }
            return ack
        } catch {
            await emit(name, Self.errorValue(error))
            return nil
        }
    }

    // MARK: - Workflow

    private func workflow(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                          _ conversation: TopicFeed<ConversationSnapshot>, _ report: inout CheckReport) async {
        guard await runStep("prompt /workflow (un prompt GLM et un petit run)", &report, { () async throws -> Void in
            let ack = try await agent.send(builder.sendText(sessionId: sessionId, text: Self.workflowPrompt, mode: "build"))
            await emit("workflow.ack", Self.summary(ack))
            guard ack.isAccepted else { throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil else { return }
        var seen: Set<String> = []
        var approvals = 0
        let workId = await runStep("run de workflow dans backgroundWorks", &report) { () async throws -> String in
            try await poll(within: turnTimeout, every: .milliseconds(500)) { () async throws -> String? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                for interaction in snapshot.pendingInteractions where !seen.contains(interaction.interactionId) {
                    seen.insert(interaction.interactionId)
                    await emit("interaction", interaction.raw)
                    guard case .permission = interaction.payload, approvals < Self.maxApprovals else {
                        throw CheckFailure("demande non accordée par la sonde (\(interaction.kind)) : voir l'enregistrement")
                    }
                    try await approveOnce(interaction, sessionId: sessionId, agent: agent, builder: builder)
                    approvals += 1
                }
                let works = snapshot.state["backgroundWorks"]?.arrayValue ?? []
                guard let work = works.first(where: { $0["kind"]?.stringValue == "workflow" }),
                      let workId = work["workId"]?.stringValue else {
                    if snapshot.control?.canStop != true, snapshot.rows.contains(where: { $0.kind == .assistantText }) {
                        throw CheckFailure("tour terminé sans run de workflow")
                    }
                    return nil
                }
                await emit("backgroundWorks", .array(works))
                await emit("workflowRuns", snapshot.state["workflowRuns"] ?? .null)
                return workId
            }
        }
        if let workId {
            await runStep("cancelBackgroundWork du run", &report) { () async throws -> Void in
                let envelope = try builder.envelope(.cancelBackgroundWork, sessionId: sessionId, payload: ["workId": .string(workId)])
                let ack = try await agent.send(envelope)
                await emit("cancelBackgroundWork", Self.summary(ack))
                guard ack.isAccepted || ack.status == .noop else {
                    throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
                }
                _ = try await poll(within: .seconds(30)) { () async throws -> Bool? in
                    guard let snapshot = try await feedValue(of: conversation) else { return nil }
                    let works = snapshot.state["backgroundWorks"]?.arrayValue ?? []
                    let work = works.first { $0["workId"]?.stringValue == workId }
                    guard work?["status"]?.stringValue != "running" else { return nil }
                    await emit("backgroundWorks.after", .array(works))
                    return true
                }
            }
        }
        await stopTurn(agent, builder, sessionId, conversation)
    }

    // MARK: - Outils

    private func subscribe(_ agent: AgentV4, _ sessionId: String) async throws -> TopicFeed<ConversationSnapshot> {
        let feed = TopicFeed<ConversationSnapshot>(
            topic: Topic.conversation(sessionId), operations: agent.conversationOperations(sessionId: sessionId))
        try await feed.start(frames: agent.conversationFrames())
        _ = try await poll(within: .seconds(15)) { try await feedValue(of: feed) }
        return feed
    }

    /// Arrête le tour s'il tourne encore (fin de la dépense) ; l'accusé est enregistré.
    private func stopTurn(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                          _ conversation: TopicFeed<ConversationSnapshot>) async {
        guard let snapshot = await conversation.current, snapshot.control?.canStop == true else { return }
        let expected = snapshot.control?.activeWorks?.first { $0.foregroundExecutionId != nil }?.foregroundExecutionId
        if let ack = try? await agent.send(builder.stop(sessionId: sessionId, expectedForegroundExecutionId: expected)) {
            await emit("stop", Self.summary(ack))
        }
    }

    /// Toujours exécuté : tours arrêtés, abonnements fermés, sessions supprimées (enfants d'abord).
    private func cleanUp(_ agent: AgentV4, _ report: inout CheckReport, _ resources: Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        for (sessionId, feed) in resources.feeds {
            await stopTurn(agent, builder, sessionId, feed)
            await feed.stop()
        }
        for sessionId in resources.sessions.reversed() {
            await runStep("suppression de \(sessionId)", &report) {
                let ack = try await agent.send(builder.deleteSession(sessionId: sessionId))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
    }

    private func emit(_ name: String, _ value: JSONValue) async {
        await output.emit(kind: "state", step: 0, name: name, value: value)
    }

    /// Appel brut enregistré tel quel (`result` ou `error`) ; rend le résultat, `nil` sur erreur.
    @discardableResult
    private func recordCall(_ client: ChannelClient, _ channel: String, _ method: String,
                            _ params: [String: JSONValue]) async -> JSONValue? {
        let name = "\(channel).\(method)"
        do {
            let value = try await client.call(channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
            await output.emit(kind: "result", step: 0, name: name, value: value)
            return value
        } catch {
            await output.emit(kind: "error", step: 0, name: name, value: Self.errorValue(error))
            return nil
        }
    }

    /// Accusé tel que l'hôte l'envoie (sans les champs absents) : réutilisable comme réponse d'un faux serveur.
    static func summary(_ ack: CommandAck) -> JSONValue {
        var object: [String: JSONValue] = ["commandId": .string(ack.commandId), "status": .string(ack.status.rawValue)]
        if let reason = ack.reasonCode { object["reasonCode"] = .string(reason) }
        if let message = ack.message { object["message"] = .string(message) }
        if let revision = ack.revisionAtDecision { object["revisionAtDecision"] = .number(Double(revision)) }
        if let result = ack.result { object["result"] = result.raw }
        return .object(object)
    }

    /// Erreur distante telle que l'hôte l'envoie, sans `stack` (chemins du runtime de l'hôte).
    static func errorValue(_ error: any Error) -> JSONValue {
        guard case RPCError.remote(let remote) = error, var object = remote.raw.objectValue else {
            return .string(String(describing: error))
        }
        object["stack"] = nil
        return .object(object)
    }
}
