import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// `zcode-probe attach` : une image de test téléversée dans une session neuve (sans premier message, comme le brouillon
/// de l'app), envoyée sans texte puis avec une question, relue par `attachmentReadV4`, et décrite par le modèle. États et
/// réponses écrits par `ProbeOutput` (`--record`). La session est supprimée à la fin.
struct AttachRun {
    static let clientId = "client-zcode-probe-attach"
    /// PNG 64 × 64 uni cramoisi (#DC143C), 137 octets.
    static let imageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAUElEQVR42u3PQQkAAAgEsAthHPunMIwRfAuDFVim+rUICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICFwWs4TBD55PN2kAAAAASUVORK5CYII="
    static let question = "De quelle couleur est l'image jointe ? Réponds en un seul mot, en français."

    let endpoint: HostEndpoint
    let workspace: String
    let output: ProbeOutput
    var timeout: Duration = .seconds(120)

    private struct Resources {
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
        let image = Data(base64Encoded: Self.imageBase64)!
        guard let sessionId = await runStep("création d'une session sans premier message", &report, { () async throws -> String in
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
            let snapshot = try await poll(within: .seconds(15)) { try await feedValue(of: conversation) }
            // Relevé seulement (point 6) : capacités d'entrée du modèle, si l'état les porte.
            await output.emit(kind: "state", step: 0, name: "config", value: snapshot.state["config"] ?? .null)
        }) != nil else { return }

        guard let ref = await runStep("téléversement (begin → chunk → commit)", &report, { () async throws -> AttachmentRef in
            let ref = try await agent.uploadAttachment(sessionId: sessionId, fileName: "carre-rouge.png", mime: "image/png",
                                                       data: image)
            await output.emit(kind: "state", step: 1, name: "ref", value: ref.json)
            guard ref.ref.contains("://") else { throw CheckFailure("référence inattendue : \(ref.ref)") }
            return ref
        }) else { return }

        // Un message sans texte est-il accepté ? Si oui, le tour qu'il lance se termine avant la question.
        var accepted = false
        await runStep("envoi sans texte (text: \"\")", &report) { () async throws -> Void in
            let ack = try await agent.send(builder.sendText(sessionId: sessionId, text: "", mode: "build", attachments: [ref]))
            await output.emit(kind: "state", step: 2, name: "empty-text-ack", value: .object([
                "status": .string(ack.status.rawValue), "reasonCode": ack.reasonCode.map(JSONValue.string) ?? .null,
                "message": ack.message.map(JSONValue.string) ?? .null,
            ]))
            accepted = ack.isAccepted
            print(accepted ? "  → l'hôte accepte un message sans texte" : "  → l'hôte REFUSE un message sans texte")
        }
        if accepted {
            let first = try? await poll(within: timeout) { () async throws -> String? in
                try await answer(in: conversation, sessionId: sessionId, agent: agent, builder: builder) { _ in true }
            }
            await output.emit(kind: "state", step: 2, name: "empty-text-answer", value: first.map(JSONValue.string) ?? .null)
        }

        await runStep("question sur l'image", &report) { () async throws -> Void in
            let ack = try await agent.send(builder.sendText(sessionId: sessionId, text: Self.question, mode: "build",
                                                            attachments: [ref]))
            guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
        }

        let questionRow = await runStep("ligne userInput avec la pièce jointe", &report) { () async throws -> ConversationRow in
            try await poll(within: .seconds(30)) {
                try await feedValue(of: conversation)?.rows.last { row in
                    if case .userInput(let input) = row.content {
                        return input.text == Self.question && input.attachments.contains { $0.ref == ref.ref }
                    }
                    return false
                }
            }
        }
        if let questionRow { await output.emit(kind: "row", step: 3, name: "userInput", value: questionRow.json) }

        await runStep("relecture (attachmentReadV4)", &report) { () async throws -> Void in
            let data = try await agent.readAttachment(sessionId: sessionId, ref: ref.readableRef)
            await output.emit(kind: "state", step: 4, name: "read", value: .object(["bytes": .number(Double(data.count))]))
            guard data == image else { throw CheckFailure("contenu relu différent (\(data.count) octets)") }
        }

        guard let questionRow else { return }
        await runStep("le modèle voit l'image (couleur)", &report) { () async throws -> Void in
            let answer = try await poll(within: timeout) { () async throws -> String? in
                try await answer(in: conversation, sessionId: sessionId, agent: agent, builder: builder) { $0 > questionRow.rowId }
            }
            await output.emit(kind: "state", step: 5, name: "answer", value: .string(answer))
            // Le modèle nomme #DC143C avec le vocabulaire de la famille rouge / rose (réel : « Magenta ») : on contrôle qu'il
            // voit une couleur de cette famille, pas un nom exact.
            let lower = answer.lowercased()
            let family = ["rouge", "cramoisi", "carmin", "pourpre", "magenta", "rose", "framboise", "red", "crimson", "pink"]
            guard family.contains(where: lower.contains) else {
                throw CheckFailure("réponse sans la couleur : \(answer)")
            }
        }
    }

    /// Dernière réponse terminée de l'assistant dont le `rowId` satisfait `accepts`, une fois le tour fini. Toute demande
    /// d'autorisation est refusée (aucun outil n'est attendu) pour ne pas bloquer.
    private func answer(in conversation: TopicFeed<ConversationSnapshot>, sessionId: String, agent: AgentV4,
                        builder: CommandBuilder, accepts: (Int) -> Bool) async throws -> String? {
        guard let snapshot = try await feedValue(of: conversation) else { return nil }
        if let interaction = snapshot.pendingInteractions.first,
           case .permission(let request) = interaction.payload,
           let option = request.options.first(where: { $0.kind == .deny }) ?? request.options.last {
            _ = try await agent.send(builder.resolveInteraction(
                sessionId: sessionId, interactionId: interaction.interactionId, answer: InteractionAnswer(optionId: option.optionId)))
            return nil
        }
        guard snapshot.control?.canStop != true else { return nil }
        for row in snapshot.rows.reversed() {
            if case .assistantText(let text) = row.content, text.state != .streaming, accepts(row.rowId) { return text.text }
        }
        return nil
    }

    /// Toujours exécuté : supprime la session.
    private func cleanUp(_ agent: AgentV4, _ report: inout CheckReport, _ resources: Resources) async {
        let builder = CommandBuilder(clientId: Self.clientId)
        await resources.conversation?.stop()
        if let sessionId = resources.sessionId {
            await runStep("suppression de la session", &report) {
                let ack = try await agent.send(builder.deleteSession(sessionId: sessionId))
                guard ack.isAccepted else { throw CheckFailure("refusée (\(ack.status), \(ack.reasonCode ?? "sans motif"))") }
            }
        }
    }
}
