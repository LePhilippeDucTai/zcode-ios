import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// `zcode-probe goal` : une vraie boucle de Goal sur l'hôte (objectif trivial, ≈ 2 à 4 appels au modèle). Chaque état
/// distinct de `snapshot.goal` et chaque marqueur `goalVerify` sont écrits par `ProbeOutput` (`--record`). Le Goal est mis
/// en pause s'il tourne encore à l'échéance, puis la session est supprimée.
struct GoalRun {
    static let clientId = "client-zcode-probe-goal"
    static let objective = "Réponds uniquement par le mot OK. Le Goal est atteint dès que tu as répondu OK."

    let endpoint: HostEndpoint
    let workspace: String
    let output: ProbeOutput
    var timeout: Duration = .seconds(180)

    private struct Resources {
        var index: TopicFeed<SessionsIndex>?
        var conversation: TopicFeed<ConversationSnapshot>?
        var sessionId: String?
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
        let index = TopicFeed<SessionsIndex>(topic: Topic.sessionsIndex(workspace), operations: agent.sessionsIndexOperations())
        resources.index = index
        guard await runStep("index des sessions", &report, { () async throws -> Void in
            try await index.start(frames: agent.sessionsIndexFrames())
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: index) }
        }) != nil else { return }

        guard let sessionId = await runStep("création d'une session", &report, { () async throws -> String in
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
        guard await runStep("abonnement à la conversation", &report, { () async throws -> Void in
            try await conversation.start(frames: agent.conversationFrames())
            _ = try await poll(within: .seconds(15)) { try await feedValue(of: conversation) }
        }) != nil else { return }

        let send = builder.sendGoal(sessionId: sessionId, objective: Self.objective, displayText: "/goal " + Self.objective,
                                    mode: "build")
        guard await runStep("lancement du Goal (sendGoalCommand)", &report, { () async throws -> Void in
            let ack = try await agent.send(send)
            await output.emit(kind: "state", step: 0, name: "ack", value: .object([
                "status": .string(ack.status.rawValue), "reasonCode": ack.reasonCode.map(JSONValue.string) ?? .null,
                "hasResult": .bool(ack.result != nil),
            ]))
            guard ack.isAccepted else { throw CheckFailure("refusé (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }) != nil else { return }

        var lastGoal: JSONValue?
        var markers: [Int: JSONValue] = [:]
        var answered: Set<String> = []
        await runStep("Goal actif dans le snapshot", &report) { () async throws -> Void in
            _ = try await poll(within: .seconds(30)) { () async throws -> Bool? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                await record(snapshot, lastGoal: &lastGoal, markers: &markers)
                guard let goal = snapshot.goal else { return nil }
                guard goal.objective == Self.objective else { throw CheckFailure("objectif reçu : « \(goal.objective) »") }
                return true
            }
        }
        let final = await runStep("Goal atteint", &report) { () async throws -> GoalState in
            try await poll(within: timeout, every: .milliseconds(500)) { () async throws -> GoalState? in
                guard let snapshot = try await feedValue(of: conversation) else { return nil }
                await record(snapshot, lastGoal: &lastGoal, markers: &markers)
                if let interaction = snapshot.pendingInteractions.first(where: { !answered.contains($0.interactionId) }) {
                    try await approveOnce(interaction, sessionId: sessionId, agent: agent, builder: builder)
                    answered.insert(interaction.interactionId)
                    return nil
                }
                guard let goal = snapshot.goal else { return nil }
                return goal.status == .verified ? goal : nil
            }
        }
        report.record("vérification observée", markers.isEmpty ? .failed("aucun marqueur goalVerify") : .passed)
        guard final != nil else { return }
        await runStep("goalStatus dans l'index", &report) {
            _ = try await poll(within: .seconds(15)) { () async throws -> Bool? in
                guard let session = try await feedValue(of: index)?.session(id: sessionId) else { return nil }
                guard session.goalStatus == .verified else { return nil }
                await output.emit(kind: "state", step: 0, name: "index", value: .object(["goalStatus": .string("verified")]))
                return true
            }
        }
    }

    /// Écrit chaque nouvel état de `goal` (null compris) et chaque marqueur `goalVerify` modifié.
    private func record(_ snapshot: ConversationSnapshot, lastGoal: inout JSONValue?, markers: inout [Int: JSONValue]) async {
        let goal = snapshot.state["goal"] ?? .null
        if goal != lastGoal {
            lastGoal = goal
            await output.emit(kind: "state", step: 0, name: "goal", value: goal)
        }
        for row in snapshot.rows where row.raw["marker"]?["type"]?.stringValue == "goalVerify" && markers[row.rowId] != row.json {
            markers[row.rowId] = row.json
            await output.emit(kind: "state", step: 0, name: "marker", value: row.json)
        }
    }

    /// Toujours exécuté : met en pause un Goal qui tourne encore (arrêt de la dépense), supprime la session.
    private func cleanUp(_ agent: AgentV4, _ report: inout CheckReport, _ resources: Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        if let sessionId = resources.sessionId, let conversation = resources.conversation,
           let snapshot = await conversation.current, let goal = snapshot.goal,
           [GoalStatus.active, .verifying, .notSatisfied].contains(goal.status) {
            await runStep("mise en pause du Goal", &report) {
                let ack = try await agent.send(builder.pauseGoal(sessionId: sessionId, base: snapshot.commandBase))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
        await resources.conversation?.stop()
        if let sessionId = resources.sessionId {
            await runStep("suppression de la session", &report) {
                let ack = try await agent.send(builder.deleteSession(sessionId: sessionId))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
        await resources.index?.stop()
    }
}
