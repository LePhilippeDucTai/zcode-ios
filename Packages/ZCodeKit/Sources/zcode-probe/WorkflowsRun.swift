import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// `zcode-probe workflows` : contrat réel des workflows enregistrés (lot 13E-2, tâche 0) dans un projet jetable
/// (`--workspace` sous `.zcode-check`), lancé **sur la machine de l'hôte** : les fichiers `.dwf.ts` sont écrits
/// directement dans `<workspace>/.zcode/workflows/` puis supprimés. Sans `--with-agent`, un seul appel GLM (la fin
/// d'un run relance toujours le modèle, question 3) : barrière, listes, refus, run trivial suivi jusqu'à la fin, annulation d'un
/// run fini, index des sessions. `--with-agent` : en plus, un agent qui veut écrire un fichier → demande remontée dans
/// la session parente, relue après reconnexion, refusée, puis run arrêté. Les noms des enregistrements (`--record`)
/// sont ceux de la tâche 0 du plan 13E-2 ; le nettoyage s'exécute même après un échec.
struct WorkflowsRun {
    static let clientId = "client-zcode-probe-workflows"

    /// Workflow trivial (aucun agent, aucun prompt) : renvoie son argument.
    static let trivialName = "ios-probe"
    static let trivialSource = """
    /* zcode-workflow
    description: Sonde iOS triviale
    args:
      who: { type: string, default: monde }
      count: { type: number, required: true }
    */
    return `bonjour ${String(args.who)} ×${Number(args.count)}`;
    """
    /// Un agent qui veut écrire un fichier : autorisation demandée selon le mode de la session. Forme de
    /// `docs/dynamic-workflow/authoring.md` : `agent(nom?, persona?)` rend un `Agent`, c'est `.ask(…)` qui travaille.
    static let agentName = "ios-probe-agent"
    static let agentSource = """
    /* zcode-workflow
    description: Sonde iOS avec un agent qui écrit un fichier
    */
    phase("Écriture");
    const r = await agent("Rédacteur").ask("Crée le fichier ios-probe-agent.txt contenant OK avec l'outil Write, puis réponds FAIT.");
    return r;
    """
    /// En-tête sans `description` : attendu dans la liste `invalid`.
    static let invalidName = "ios-probe-invalide"
    static let invalidSource = """
    /* zcode-workflow
    whenToUse: jamais (en-tête volontairement sans description)
    */
    return 1;
    """
    static let agentOutputFile = "ios-probe-agent.txt"
    static let terminalRunStatuses: Set<String> = ["completed", "errored", "stopped"]
    static let knownDeltaOps: Set<String> = ["row.appended", "row.upserted", "row.removed", "row.delta", "state.updated"]

    let endpoint: HostEndpoint
    let workspace: String
    let withAgent: Bool
    let cancelWhilePending: Bool
    let sessionMode: String?
    let output: ProbeOutput
    var runTimeout: Duration = .seconds(60)
    var permissionTimeout: Duration = .seconds(120)

    private struct Resources {
        /// Sessions créées : supprimées à la fin.
        var sessions: [String] = []
        var feeds: [(sessionId: String, feed: TopicFeed<ConversationSnapshot>)] = []
        var index: TopicFeed<SessionsIndex>?
    }

    private var workflowsDirectory: URL { URL(filePath: workspace).appending(path: ".zcode/workflows") }

    func run() async -> CheckReport {
        var report = CheckReport()
        let log = FrameLog()
        await runStep("fichiers de workflow écrits dans le projet", &report) { try writeWorkflowFiles() }
        if let client = await runStep("connexion WebSocket", &report, { try await ZCodeConnector.connect(to: endpoint) }) {
            let agent = AgentV4(client: client, workspacePath: workspace)
            if await runStep("handshake V4", &report, { try await agent.handshake(clientId: Self.clientId, appVersion: "zcode-probe") }) != nil {
                var resources = Resources()
                await exercise(agent, log, &report, &resources)
                await emit("deltas.unknown", await log.summary())
                await cleanUp(agent, &report, resources)
            }
            await client.close()
        }
        removeLocalFiles()
        return report
    }

    // MARK: - Étapes

    private func exercise(_ agent: AgentV4, _ log: FrameLog, _ report: inout CheckReport, _ resources: inout Resources) async {
        let client = agent.client
        await recordCall(client, "coding-plan-subscription", "getDynamicWorkflowClientConfig", nil, name: "workflow.config")
        await runStep("liste des workflows du projet (valide + invalide)", &report) { () async throws -> Void in
            let list = await recordCall(client, "zcode-agent", "listSavedWorkflows",
                                        ["workspacePath": .string(workspace)], name: "list.project")
            let names = (list?["workflows"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            let invalid = (list?["invalid"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            guard names.contains(Self.trivialName) else { throw CheckFailure("\(Self.trivialName) absent : \(names)") }
            guard invalid.contains(where: { $0.hasSuffix("\(Self.invalidName).dwf.ts") }) else {
                throw CheckFailure("\(Self.invalidName) absent de invalid : \(invalid)")
            }
        }
        await recordCall(client, "zcode-agent", "listSavedWorkflows", ["scope": .string("global")], name: "list.global")

        let index = TopicFeed<SessionsIndex>(topic: Topic.sessionsIndex(workspace), operations: agent.sessionsIndexOperations())
        resources.index = index
        await runStep("index des sessions du projet", &report) { () async throws -> Void in
            try await index.start(frames: tap(agent.sessionsIndexFrames(), log, index: true))
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: index) }
        }

        let builder = CommandBuilder(clientId: Self.clientId)
        guard let (sessionId, conversation) = await newSession(agent, builder, log, name: "createSession.ack", &report, &resources) else {
            return
        }
        if let snapshot = await conversation.current {
            await emit("state.initial", Self.stateWithoutRows(snapshot))
            print("  → config.mode de la session créée : \(snapshot.state["config"]?["mode"]?.stringValue ?? "absent")")
        }

        // Refus sans effet sur la session vide, avant tout lancement (sinon `session_busy`).
        await expectRejection(agent, builder, sessionId, ["name": .string("inexistant")],
                              reason: "not_found", name: "start.notFound.ack", &report)
        await expectRejection(agent, builder, sessionId,
                              ["name": .string(Self.trivialName), "args": .object(["count": .string("abc")])],
                              reason: "invalid_args", name: "start.invalidArgs.ack", &report)

        guard let launch = await runStep("startSavedWorkflow du workflow trivial", &report, { () async throws -> (String, String) in
            let ack = try await agent.send(builder.envelope(.startSavedWorkflow, sessionId: sessionId, payload: [
                "name": .string(Self.trivialName), "scope": .string("project"), "args": .object(["count": .number(2)]),
            ]))
            await emit("start.trivial.ack", ComposerRun.summary(ack))
            guard ack.isAccepted, let runId = ack.result?.raw["runId"]?.stringValue,
                  let toolCallId = ack.result?.raw["toolCallId"]?.stringValue else {
                throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif") : \(ack.message ?? ""))")
            }
            return (runId, toolCallId)
        }) else { return }
        let (runId, toolCallId) = launch

        await followRun(conversation, runId: runId, toolCallId: toolCallId, prefix: "state.trivial", &report)
        if let snapshot = await conversation.current {
            await emit("state.trivial.final", Self.stateWithoutRows(snapshot))
            await emit("rows.trivial.final", .array(snapshot.rows.map(\.json)))
        }
        await watchAfterResult(agent, builder, sessionId, conversation, name: "state.trivial.afterResult", &report)

        await runStep("cancelBackgroundWork sur le run fini (accusé enregistré)", &report) { () async throws -> Void in
            let ack = try await agent.send(builder.envelope(.cancelBackgroundWork, sessionId: sessionId,
                                                            payload: ["workId": .string(runId)]))
            await emit("cancel.finished.ack", ComposerRun.summary(ack))
        }
        await recordIndexSummary(log, sessionId, name: "index.trivial", &report)

        if withAgent {
            await agentScenario(agent, builder, log, &report, &resources)
        }
    }

    // MARK: - Agent qui demande une autorisation

    private func agentScenario(_ agent: AgentV4, _ builder: CommandBuilder, _ log: FrameLog,
                               _ report: inout CheckReport, _ resources: inout Resources) async {
        guard let (sessionId, conversation) = await newSession(agent, builder, log, name: "createSession.agent.ack",
                                                               &report, &resources) else { return }
        guard let runId = await runStep("startSavedWorkflow du workflow avec agent", &report, { () async throws -> String in
            let ack = try await agent.send(builder.envelope(.startSavedWorkflow, sessionId: sessionId, payload: [
                "name": .string(Self.agentName), "scope": .string("project"),
            ]))
            await emit("start.agent.ack", ComposerRun.summary(ack))
            guard ack.isAccepted, let runId = ack.result?.raw["runId"]?.stringValue else {
                throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif") : \(ack.message ?? ""))")
            }
            return runId
        }) else { return }

        let request = await runStep("demande d'autorisation dans la session parente", &report) {
            () async throws -> PendingInteraction in
            try await poll(within: permissionTimeout, every: .milliseconds(500)) { () async throws -> PendingInteraction? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                if let interaction = snapshot.pendingInteractions.first {
                    await emit("state.agent.permission", Self.permissionView(snapshot, interaction))
                    return interaction
                }
                if let status = Self.runStatus(snapshot, runId), Self.terminalRunStatuses.contains(status) {
                    await emit("state.agent.permission", Self.runView(snapshot, toolCallId: nil))
                    throw CheckFailure("run fini (\(status)) sans demande d'autorisation")
                }
                return nil
            }
        }
        if let request {
            let origin = request.origin
            report.record("origine subagent (\(origin?.description ?? "sans description"))",
                          origin?.kind == "subagent" ? .passed : .failed("origin = \(origin?.kind ?? "absente")"))
            await reconnectAndReread(request, sessionId, &report)
        }

        // Abonnement neuf sur la connexion d'origine pour la suite.
        await conversation.stop()
        guard let fresh = await runStep("réabonnement à la session parente", &report, {
            try await subscribe(agent, sessionId, log)
        }) else { return }
        resources.feeds.append((sessionId, fresh))

        // Refus de la demande puis suivi 30 s (toute nouvelle demande refusée aussi) ; avec `--cancel`, rien de tout
        // ça : « Arrêter » part aussitôt, la demande encore en attente.
        var denied: Set<String> = []
        if request != nil, !cancelWhilePending {
            await runStep("refus de la demande (option deny)", &report) { () async throws -> Void in
                guard let snapshot = try await feedValue(of: fresh), let interaction = snapshot.pendingInteractions.first else {
                    throw CheckFailure("plus de demande en attente")
                }
                denied.insert(interaction.interactionId)
                let ack = try await denyOnce(interaction, sessionId: sessionId, agent: agent, builder: builder)
                await emit("resolve.deny.ack", ComposerRun.summary(ack))
                guard ack.isAccepted else { throw CheckFailure("refus rejeté (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
        var extraDenials = 0
        let deadline = ContinuousClock.now.advanced(by: cancelWhilePending ? .zero : .seconds(30))
        while ContinuousClock.now < deadline {
            guard let snapshot = await fresh.current else { break }
            if let status = Self.runStatus(snapshot, runId), Self.terminalRunStatuses.contains(status) { break }
            for interaction in snapshot.pendingInteractions where !denied.contains(interaction.interactionId) && extraDenials < 4 {
                denied.insert(interaction.interactionId)
                await emit("state.agent.extraPermission", Self.permissionView(snapshot, interaction))
                if let ack = try? await denyOnce(interaction, sessionId: sessionId, agent: agent, builder: builder) {
                    await emit("resolve.extraDeny.ack", ComposerRun.summary(ack))
                }
                extraDenials += 1
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let snapshot = await fresh.current {
            if !cancelWhilePending { await emit("state.agent.afterDeny", Self.runView(snapshot, toolCallId: nil)) }
            let status = Self.runStatus(snapshot, runId)
            if status == nil || !Self.terminalRunStatuses.contains(status ?? "") {
                await runStep("cancelBackgroundWork du run en cours (« Arrêter »)", &report) { () async throws -> Void in
                    let ack = try await agent.send(builder.envelope(.cancelBackgroundWork, sessionId: sessionId,
                                                                    payload: ["workId": .string(runId)]))
                    await emit("cancel.running.ack", ComposerRun.summary(ack))
                    guard ack.isAccepted || ack.status == .noop else {
                        throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
                    }
                    _ = try await poll(within: .seconds(30), every: .milliseconds(500)) { () async throws -> Bool? in
                        guard let snapshot = try await feedValue(of: fresh),
                              let status = Self.runStatus(snapshot, runId) else { return nil }
                        return Self.terminalRunStatuses.contains(status) ? true : nil
                    }
                }
            }
        }
        if cancelWhilePending {
            let cleared = try? await poll(within: .seconds(10), every: .milliseconds(500)) {
                await fresh.current?.pendingInteractions.isEmpty == true ? true : nil
            }
            report.record("demande de l'agent retirée après l'arrêt",
                          cleared == true ? .passed : .warning("toujours en attente 10 s après l'arrêt"))
        }
        if let snapshot = await fresh.current {
            await emit("state.agent.final", Self.stateWithoutRows(snapshot))
            await emit("rows.agent.final", .array(snapshot.rows.map(\.json)))
        }
        await watchAfterResult(agent, builder, sessionId, fresh, name: "state.agent.afterResult", &report)
        await recordIndexSummary(log, sessionId, name: "index.agent", &report)
    }

    /// Question 2 : nouvelle connexion WebSocket (comme l'app après une coupure), handshake, abonnement neuf, la
    /// demande doit y être encore.
    private func reconnectAndReread(_ request: PendingInteraction, _ sessionId: String, _ report: inout CheckReport) async {
        await runStep("demande toujours là après reconnexion", &report) { () async throws -> Void in
            let client = try await ZCodeConnector.connect(to: endpoint)
            defer { Task { await client.close() } }
            let agent = AgentV4(client: client, workspacePath: workspace)
            try await agent.handshake(clientId: Self.clientId, appVersion: "zcode-probe")
            let feed = try await subscribe(agent, sessionId, nil)
            defer { Task { await feed.stop() } }
            guard let snapshot = try await feedValue(of: feed) else { throw CheckFailure("aucun état") }
            await emit("state.agent.afterResubscribe", Self.runView(snapshot, toolCallId: nil))
            guard snapshot.pendingInteractions.contains(where: { $0.interactionId == request.interactionId }) else {
                throw CheckFailure("demande \(request.interactionId) absente après reconnexion")
            }
        }
    }

    // MARK: - Suivi d'un run

    /// Émet `prefix.<n>` à chaque changement de `backgroundWorks`, `workflowRuns` ou des lignes du lancement, jusqu'à
    /// un statut de run terminal.
    private func followRun(_ conversation: TopicFeed<ConversationSnapshot>, runId: String, toolCallId: String,
                           prefix: String, _ report: inout CheckReport) async {
        var last: JSONValue?
        var count = 0
        await runStep("run \(runId) terminé", &report) { () async throws -> Void in
            let status = try await poll(within: runTimeout, every: .milliseconds(250)) { () async throws -> String? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                let view = Self.runView(snapshot, toolCallId: toolCallId)
                if view != last {
                    last = view
                    count += 1
                    await emit("\(prefix).\(count)", view)
                }
                guard let status = Self.runStatus(snapshot, runId), Self.terminalRunStatuses.contains(status) else { return nil }
                return status
            }
            print("  → statut final : \(status)")
        }
    }

    /// Question 3 : la fin du run relance-t-elle le modèle ? 20 s d'observation ; si un tour démarre, il est émis
    /// puis arrêté.
    private func watchAfterResult(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                                  _ conversation: TopicFeed<ConversationSnapshot>, name: String,
                                  _ report: inout CheckReport) async {
        guard let before = await conversation.current else { return }
        let headersBefore = before.rows.filter { $0.kind == .turnHeader }.count
        var started: ConversationSnapshot?
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard let snapshot = await conversation.current else { continue }
            let headers = snapshot.rows.filter { $0.kind == .turnHeader }.count
            if snapshot.control?.phase == .running || headers > headersBefore {
                started = snapshot
                break
            }
        }
        guard let started else {
            report.record("fin du run sans nouveau tour du modèle (20 s)", .passed)
            return
        }
        var view = Self.stateWithoutRows(started).objectValue ?? [:]
        view["newRows"] = .array(started.rows.filter { $0.rowId > (before.rows.last?.rowId ?? -1) }.map(\.json))
        await emit(name, .object(view))
        report.record("fin du run : un tour du modèle démarre", .warning("tour arrêté par la sonde"))
        // Laisse le tour se déclarer arrêtable, puis l'arrête (fin de la dépense).
        _ = try? await poll(within: .seconds(5)) { await conversation.current?.control?.canStop == true ? true : nil }
        await stopTurn(agent, builder, sessionId, conversation)
    }

    private func recordIndexSummary(_ log: FrameLog, _ sessionId: String, name: String, _ report: inout CheckReport) async {
        await runStep("résumé de la session dans l'index (\(name))", &report) { () async throws -> Void in
            let summary = try? await poll(within: .seconds(10), every: .milliseconds(500)) { await log.indexSession(sessionId) }
            await emit(name, summary ?? .null)
            guard summary != nil else { throw CheckFailure("session absente de l'index") }
        }
    }

    // MARK: - Outils

    private func newSession(_ agent: AgentV4, _ builder: CommandBuilder, _ log: FrameLog, name: String,
                            _ report: inout CheckReport, _ resources: inout Resources)
        async -> (String, TopicFeed<ConversationSnapshot>)? {
        guard let sessionId = await runStep("création d'une session (\(sessionMode.map { "mode \($0)" } ?? "sans config"))", &report, {
            () async throws -> String in
            let ack = try await agent.send(builder.createSession(workspaceId: workspace, mode: sessionMode))
            await emit(name, ComposerRun.summary(ack))
            guard ack.isAccepted, let sessionId = ack.result?.sessionId else {
                throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))")
            }
            return sessionId
        }) else { return nil }
        resources.sessions.append(sessionId)
        guard let feed = await runStep("abonnement à la conversation", &report, { try await subscribe(agent, sessionId, log) }) else {
            return nil
        }
        resources.feeds.append((sessionId, feed))
        return (sessionId, feed)
    }

    private func expectRejection(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                                 _ payload: [String: JSONValue], reason: String, name: String,
                                 _ report: inout CheckReport) async {
        await runStep("refus \(reason)", &report) { () async throws -> Void in
            let ack = try await agent.send(builder.envelope(.startSavedWorkflow, sessionId: sessionId, payload: payload))
            await emit(name, ComposerRun.summary(ack))
            let expected = "fault.command.savedWorkflowStartRejected.\(reason)"
            guard !ack.isAccepted, ack.reasonCode == expected else {
                throw CheckFailure("attendu \(expected), reçu \(ack.status) \(ack.reasonCode ?? "sans motif")")
            }
        }
    }

    private func subscribe(_ agent: AgentV4, _ sessionId: String, _ log: FrameLog?) async throws -> TopicFeed<ConversationSnapshot> {
        let feed = TopicFeed<ConversationSnapshot>(
            topic: Topic.conversation(sessionId), operations: agent.conversationOperations(sessionId: sessionId))
        let frames = try await agent.conversationFrames()
        try await feed.start(frames: log.map { tap(frames, $0, index: false) } ?? frames)
        _ = try await poll(within: .seconds(15)) { try await feedValue(of: feed) }
        return feed
    }

    /// Relais qui note les trames brutes (opérations inconnues, résumés de l'index) avant le `TopicFeed`.
    private func tap(_ source: AsyncStream<JSONValue>, _ log: FrameLog, index: Bool) -> AsyncStream<JSONValue> {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let relay = Task {
            var assembler = WireAssembler()
            for await wire in source {
                for event in assembler.accept(wire, now: .now) {
                    if case .complete(let logical) = event, let frame = try? TopicFrame(json: logical.frame) {
                        await log.note(frame, index: index)
                    }
                }
                continuation.yield(wire)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }

    /// Refuse une demande d'autorisation par son option `deny` (jumeau de `approveOnce`).
    private func denyOnce(_ interaction: PendingInteraction, sessionId: String, agent: AgentV4,
                          builder: CommandBuilder) async throws -> CommandAck {
        guard case .permission(let request) = interaction.payload else {
            throw CheckFailure("interaction inattendue : \(interaction.kind)")
        }
        guard let option = request.options.first(where: { $0.kind == .deny }) else {
            throw CheckFailure("aucune option deny (\(request.options.map(\.kind.rawValue)))")
        }
        return try await agent.send(builder.resolveInteraction(
            sessionId: sessionId, interactionId: interaction.interactionId, answer: InteractionAnswer(optionId: option.optionId)))
    }

    private func stopTurn(_ agent: AgentV4, _ builder: CommandBuilder, _ sessionId: String,
                          _ conversation: TopicFeed<ConversationSnapshot>) async {
        guard let snapshot = await conversation.current, snapshot.control?.canStop == true else { return }
        let expected = snapshot.control?.activeWorks?.first { $0.foregroundExecutionId != nil }?.foregroundExecutionId
        if let ack = try? await agent.send(builder.stop(sessionId: sessionId, expectedForegroundExecutionId: expected)) {
            await emit("stop", ComposerRun.summary(ack))
        }
    }

    /// Toujours exécuté : tours arrêtés, abonnements fermés, sessions supprimées.
    private func cleanUp(_ agent: AgentV4, _ report: inout CheckReport, _ resources: Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        for (sessionId, feed) in resources.feeds {
            await stopTurn(agent, builder, sessionId, feed)
            await feed.stop()
        }
        await resources.index?.stop()
        for sessionId in resources.sessions.reversed() {
            await runStep("suppression de \(sessionId)", &report) {
                let ack = try await agent.send(builder.deleteSession(sessionId: sessionId))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
    }

    private func writeWorkflowFiles() throws {
        try FileManager.default.createDirectory(at: workflowsDirectory, withIntermediateDirectories: true)
        var files = [(Self.trivialName, Self.trivialSource), (Self.invalidName, Self.invalidSource)]
        if withAgent { files.append((Self.agentName, Self.agentSource)) }
        for (name, source) in files {
            try Data((source + "\n").utf8).write(to: workflowsDirectory.appending(path: "\(name).dwf.ts"))
        }
    }

    /// Les trois fichiers de workflow et le fichier que l'agent aurait écrit ; le reste du projet jetable (brouillons,
    /// journaux de run de l'hôte) part avec `rm -rf` du dossier `.zcode-check`.
    private func removeLocalFiles() {
        for name in [Self.trivialName, Self.invalidName, Self.agentName] {
            try? FileManager.default.removeItem(at: workflowsDirectory.appending(path: "\(name).dwf.ts"))
        }
        try? FileManager.default.removeItem(at: URL(filePath: workspace).appending(path: Self.agentOutputFile))
    }

    private func emit(_ name: String, _ value: JSONValue) async {
        await output.emit(kind: "state", step: 0, name: name, value: value)
    }

    /// Appel brut enregistré tel quel sous `name` (`result` ou `error`) ; rend le résultat, `nil` sur erreur.
    @discardableResult
    private func recordCall(_ client: ChannelClient, _ channel: String, _ method: String,
                            _ params: [String: JSONValue]?, name: String) async -> JSONValue? {
        do {
            let args: RPCValue = params.map { .array([RPCValue(.object($0))]) } ?? .array([])
            let value = try await client.call(channel, method, args).jsonValue ?? .null
            await output.emit(kind: "result", step: 0, name: name, value: value)
            return value
        } catch {
            await output.emit(kind: "error", step: 0, name: name, value: ComposerRun.errorValue(error))
            return nil
        }
    }

    // MARK: - Vues enregistrées

    static func stateWithoutRows(_ snapshot: ConversationSnapshot) -> JSONValue {
        var state = snapshot.state
        state["rows"] = nil
        return .object(state)
    }

    static func runStatus(_ snapshot: ConversationSnapshot, _ runId: String) -> String? {
        let runs = snapshot.state["workflowRuns"]?["runs"]?.arrayValue ?? []
        return runs.first { $0["runId"]?.stringValue == runId }?["status"]?.stringValue
    }

    /// `{backgroundWorks, workflowRuns, control, pendingInteractions, launchRows}` ; `launchRows` = lignes dont le JSON
    /// contient le `toolCallId` du lancement (ligne de lancement, en-tête de tour).
    static func runView(_ snapshot: ConversationSnapshot, toolCallId: String?) -> JSONValue {
        var view: [String: JSONValue] = [
            "backgroundWorks": snapshot.state["backgroundWorks"] ?? .null,
            "workflowRuns": snapshot.state["workflowRuns"] ?? .null,
            "control": snapshot.state["control"] ?? .null,
            "pendingInteractions": snapshot.state["pendingInteractions"] ?? .null,
        ]
        if let toolCallId {
            view["launchRows"] = .array(snapshot.rows.filter { contains(.object($0.raw), toolCallId) }.map(\.json))
        }
        return .object(view)
    }

    static func permissionView(_ snapshot: ConversationSnapshot, _ interaction: PendingInteraction) -> JSONValue {
        var view = runView(snapshot, toolCallId: nil).objectValue ?? [:]
        view["interaction"] = interaction.raw
        if case .permission(let request) = interaction.payload {
            view["optionKinds"] = .array(request.options.map { .string($0.kind.rawValue) })
        }
        view["origin"] = interaction.raw["payload"]?["origin"] ?? .null
        return .object(view)
    }

    static func contains(_ value: JSONValue, _ needle: String) -> Bool {
        switch value {
        case .string(let string): return string == needle
        case .array(let items): return items.contains { contains($0, needle) }
        case .object(let object): return object.values.contains { contains($0, needle) }
        default: return false
        }
    }
}

/// Trames brutes vues pendant la sonde : opérations de delta (question 1) et derniers résumés bruts de l'index
/// (`workflowActivity`, absent du `SessionSummary` décodé).
actor FrameLog {
    private var opCounts: [String: Int] = [:]
    private var stateKeys: Set<String> = []
    private var indexSessions: [String: JSONValue] = [:]

    func note(_ frame: TopicFrame, index: Bool) {
        switch frame.payload {
        case .snapshot(let snapshot) where index:
            for session in snapshot["sessions"]?.arrayValue ?? [] {
                if let id = session["sessionId"]?.stringValue { indexSessions[id] = session }
            }
        case .deltas(let deltas):
            for delta in deltas {
                let op = delta["op"]?.stringValue ?? ""
                if index {
                    if op == "session.upserted", let session = delta["session"], let id = session["sessionId"]?.stringValue {
                        indexSessions[id] = session
                    }
                } else {
                    opCounts[op, default: 0] += 1
                    if op == "state.updated" { stateKeys.formUnion(delta["patch"]?.objectValue?.keys ?? [:].keys) }
                }
            }
        default:
            break
        }
    }

    func indexSession(_ id: String) -> JSONValue? { indexSessions[id] }

    func summary() -> JSONValue {
        let unknown = opCounts.keys.filter { !WorkflowsRun.knownDeltaOps.contains($0) }.sorted()
        return .object([
            "unknownOps": .array(unknown.map(JSONValue.string)),
            "opCounts": .object(opCounts.mapValues { .number(Double($0)) }),
            "stateUpdatedKeys": .array(stateKeys.sorted().map(JSONValue.string)),
        ])
    }
}
