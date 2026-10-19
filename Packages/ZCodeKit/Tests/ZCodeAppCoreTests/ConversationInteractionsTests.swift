import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Accusé de statut `status` pour l'enveloppe reçue (fonction libre : appelée depuis les gestionnaires `@Sendable`).
func interactionAck(_ argument: JSONValue, _ status: String, reasonCode: String? = nil) -> JSONValue {
    var ack: [String: JSONValue] = [
        "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string(status), "revisionAtDecision": .number(9),
    ]
    if let reasonCode { ack["reasonCode"] = .string(reasonCode) }
    return .object(ack)
}

@MainActor
struct ConversationInteractionsTests {
    /// Conversation PONG prête, avec les demandes `ids` en attente.
    func readyModel(_ server: FakeZCodeServer, pending ids: [String]) async throws -> ConversationModel {
        let interactions = try ids.map(syntheticInteraction)
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame { $0["pendingInteractions"] = .array(interactions) })
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func commands(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func autorisationAccordeePuisRetireeParLHote() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, pending: ["perm_bash", "ask_style"])
        let current = try #require(model.currentInteraction)
        #expect(current.interactionId == "perm_bash")
        #expect(model.queuedInteractionCount == 1)
        #expect(await model.respond(to: current, with: InteractionAnswer(optionId: "allowOnce")))
        let envelope = try #require(await commands(server).first)
        #expect(envelope["type"] == .string("resolveInteraction"))
        #expect(envelope["sessionId"] == .string(pongSession))
        #expect(envelope["baseRevision"] == nil)
        #expect(envelope["payload"] == .object([
            "interactionId": .string("perm_bash"), "answer": .object(["optionId": .string("allowOnce")]),
        ]))
        // Répondue : la suivante s'affiche sans attendre l'état de l'hôte.
        #expect(model.currentInteraction?.interactionId == "ask_style")
        #expect(model.queuedInteractionCount == 0)
        #expect(model.respondingInteractionId == nil)
        await server.emit(conversationEvent, try conversationDeltas([pendingPatch([try syntheticInteraction("ask_style")])]))
        _ = try await eventually { model.snapshot?.pendingInteractions.count == 1 ? true : nil }
        #expect(model.currentInteraction?.interactionId == "ask_style")
        #expect(model.commandError == nil)
        #expect(model.unconfirmedCount == 0)
    }

    @Test func reponduAilleursSansErreur() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, "noop", reasonCode: "proto.alreadyResolved")
        }
        let model = try await readyModel(server, pending: ["perm_bash"])
        let current = try #require(model.currentInteraction)
        #expect(await model.respond(to: current, with: InteractionAnswer(optionId: "deny")))
        #expect(model.currentInteraction == nil)
        #expect(model.commandError == nil)
    }

    @Test func refusAfficheEtDemandeGardee() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, "rejected", reasonCode: "proto.invalidPayload")
        }
        let model = try await readyModel(server, pending: ["ask_style"])
        let current = try #require(model.currentInteraction)
        #expect(await model.respond(to: current, with: .decline) == false)
        #expect(model.commandError == "Message refusé par l'hôte (contenu invalide).")
        #expect(model.currentInteraction?.interactionId == "ask_style")
        #expect(model.respondingInteractionId == nil)
    }

    @Test func coupurePendantLaReponseJamaisRenvoyee() async throws {
        let (first, second, servers) = try await cutAndResumeServers { _ in .string("unknown") }
        let model = makeConversation(servers)
        await model.start()
        let pending = JSONValue.array([try syntheticInteraction("perm_bash")])
        try await emitConversation(first, initialConversationFrame { $0["pendingInteractions"] = pending })
        _ = try await eventually { model.phase == .ready ? true : nil }
        let current = try #require(model.currentInteraction)
        #expect(await model.respond(to: current, with: InteractionAnswer(optionId: "allowOnce")) == false)
        #expect(model.unconfirmedCount == 0)                                     // pas de bannière de vérification
        #expect(model.commandError == "Réponse peut-être non transmise : si la demande reste affichée, réponds à nouveau.")
        // Reprise sur le second serveur : rien n'est rapproché ni renvoyé, la demande est toujours là.
        try await emitConversation(second, initialConversationFrame { $0["pendingInteractions"] = pending })
        // Abonnement du second serveur fait et état reçu (`begin` repasse par `.loading` avant de s'abonner).
        _ = try await eventually {
            (await second.calls(to: "zcode-agent.subscribeConversationV4").isEmpty) || model.phase != .ready ? nil : true
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await second.calls(to: "zcode-agent.queryConversationCommandsV4").isEmpty)
        #expect(await second.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)
        #expect(model.currentInteraction?.interactionId == "perm_bash")
    }

    @Test func demandeRepresenteeApresReprise() async throws {
        // Réponse acceptée, puis coupure : si l'hôte présente toujours la demande au nouvel abonnement (réponse perdue
        // côté hôte, redémarrage), elle doit réapparaître au lieu de rester masquée.
        let first = try await conversationServer()
        let second = try await conversationServer()
        let model = makeConversation(ServerQueue([first, second]))
        await model.start()
        let pending = JSONValue.array([try syntheticInteraction("perm_bash")])
        try await emitConversation(first, initialConversationFrame { $0["pendingInteractions"] = pending })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.respond(to: try #require(model.currentInteraction), with: InteractionAnswer(optionId: "allowOnce")))
        #expect(model.currentInteraction == nil)
        first.transport.finish()                                                 // coupure
        try await emitConversation(second, initialConversationFrame { $0["pendingInteractions"] = pending })
        _ = try await eventually { model.currentInteraction?.interactionId == "perm_bash" ? true : nil }
    }

    @Test func compteAReboursSuspenduUneSeuleFois() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, pending: ["ask_style"])
        let current = try #require(model.currentInteraction)
        await model.pauseAutoResolution(of: current)
        await model.pauseAutoResolution(of: current)
        let sent = await commands(server)
        #expect(sent.map { $0["type"] } == [.string("snoozeInteractionAutoResolution")])
        #expect(sent.first?["payload"] == .object(["interactionId": .string("ask_style")]))
        #expect(sent.first?["baseRevision"] == nil)
        #expect(model.unconfirmedCount == 0)
    }

    @Test func compteAReboursRetenteSiNonConfirme() async throws {
        let server = try await conversationServer()
        let attempts = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, attempts.next() == 1 ? "failed" : "accepted")
        }
        let model = try await readyModel(server, pending: ["ask_style"])
        let current = try #require(model.currentInteraction)
        await model.pauseAutoResolution(of: current)
        await model.pauseAutoResolution(of: current)
        await model.pauseAutoResolution(of: current)
        #expect(await commands(server).count == 2)                               // échec puis succès, puis plus rien
    }

    @Test func sansCompteAReboursRienAEnvoyer() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, pending: ["perm_bash"])
        await model.pauseAutoResolution(of: try #require(model.currentInteraction))
        #expect(await commands(server).isEmpty)
    }

    @Test func revueDesHooksLaisseeALInterfaceWeb() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server, pending: ["hook_1", "perm_bash"])
        #expect(model.currentInteraction?.interactionId == "perm_bash")          // la revue des hooks est sautée
        #expect(model.queuedInteractionCount == 0)
        #expect(model.unsupportedInteractionCount == 1)
        let alone = try await readyModel(try await conversationServer(), pending: ["hook_1"])
        #expect(alone.currentInteraction == nil)
        #expect(alone.unsupportedInteractionCount == 1)
    }
}
