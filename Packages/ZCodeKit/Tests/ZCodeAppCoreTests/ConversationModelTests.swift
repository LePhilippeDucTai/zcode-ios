import Foundation
import Observation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationModelTests {
    /// Modèle abonné à la conversation PONG, trame initiale reçue.
    func readyModel(_ server: FakeZCodeServer, frame: JSONValue? = nil) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, frame ?? initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func chargementDeLaConversation() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(model.turnCount == 1)
        #expect(model.title == "Demande de réponse PONG")
        #expect(model.hasOlderRows == false)
        #expect(model.canStop == false)
        #expect(model.routing == "startNow")
        let subscribe = try #require(await server.calls(to: "zcode-agent.subscribeConversationV4").first)
        #expect(subscribe["sessionId"] == .string(pongSession))
        #expect(subscribe["base"] == nil)                                   // abonnement neuf : sans base
    }

    @Test func envoiSansLivraisonImposee() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.send("  réponds moi PONG \n") == .sent(delivery: "startNow"))
        let command = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first)
        #expect(command["envelope"]?["type"] == .string("sendText"))
        #expect(command["envelope"]?["sessionId"] == .string(pongSession))
        // Sans catalogue : la sélection de la session (GLM-5.3, effort max) part avec le mode ; jamais de `requestedDelivery`.
        #expect(command["envelope"]?["payload"] == .object([
            "text": .string("réponds moi PONG"), "inputOrigin": .string("mobile"),
            "modelSelection": .object([
                "providerId": .string("account:zai-individual-coding-plan"), "modelId": .string("GLM-5.3"),
                "options": .object(["reasoningLevel": .string("max")]),
            ]),
            "mode": .string("build"), "planEnabled": .bool(false),
        ]))
        for prefix in ["006", "007", "008", "009"] {
            await server.emit(conversationEvent, try conversationRecord(prefix))
        }
        // Le deuxième tour apparaît dès la première trame : on attend la dernière (tour terminé).
        _ = try await eventually {
            model.turnCount == 2 && model.entries.last?.turnState == .completedSuccess ? true : nil
        }
        #expect(model.commandError == nil)
    }

    @Test func choixDuComposeurNonEcrase() async throws {
        let revisions = Recorder<Int>()
        revisions.append(4)
        let server = try await catalogServer(revisions: revisions)
        let ack = try conversationRecord("003")
        await server.on("zcode-agent.subscribeConversationV4") { _ in ack }
        await server.on("zcode-agent.unsubscribeConversationV4") { _ in .null }
        await server.on("zcode-agent.sendConversationCommandV4") { acceptedAck($0) }
        let servers = ServerQueue([server])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        let catalog = ModelCatalog(connection: connection)
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, catalog: catalog)
        await catalog.start()
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.settings != nil ? true : nil }
        #expect(model.settings?.selection?.modelId == "GLM-5.3")                // config de la session
        model.selectModel(providerId: "new-provider", modelId: "mistral-large-4")
        #expect(model.effortLevels == ["none"])
        await server.emit(conversationEvent, try conversationRecord("006"))     // trame suivante, toujours GLM
        _ = try await eventually { model.snapshot?.revision == 10 ? true : nil }
        #expect(model.settings?.selection?.modelId == "mistral-large-4")
        model.selectMode("plan")
        #expect(await model.send("bonjour") == .sent(delivery: "startNow"))
        let payload = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"]?["payload"])
        #expect(payload["modelSelection"] == .object([
            "providerId": .string("new-provider"), "modelId": .string("mistral-large-4"),
            "options": .object(["reasoningLevel": .string("none")]),
        ]))
        #expect(payload["mode"] == .string("build"))
        #expect(payload["planEnabled"] == .bool(true))
    }

    @Test func reglagesInitialisesAuPremierSnapshotAvecConfig() async throws {
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame { $0["config"] = nil })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.snapshot?.config == nil)
        #expect(model.settings == nil)                                          // pas de config : rien à initialiser
        // Trame suivante : la config de la session arrive par un patch d'état.
        let config = try #require(try initialConversationFrame()["frame"]?["payload"]?["snapshot"]?["config"])
        var wire = try #require(try conversationRecord("006").objectValue)
        var frame = try #require(wire["frame"]?.objectValue)
        frame["payload"] = .object(["kind": .string("deltas"), "deltas": .array([
            .object(["op": .string("state.updated"), "patch": .object(["config": config, "revision": .number(10)])]),
        ])])
        wire["frame"] = .object(frame)
        await server.emit(conversationEvent, .object(wire))
        _ = try await eventually { model.settings != nil ? true : nil }
        #expect(model.settings?.selection?.modelId == "GLM-5.3")
    }

    /// Renommage : l'hôte pousse `state.updated {meta}` sur le sujet de la conversation (`onSessionTitleUpdated`,
    /// ZCode 3.15.1) ; le titre de la session ouverte suit sans réabonnement.
    @Test func titreRafraichiParLePatchMeta() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(model.title == "Demande de réponse PONG")
        var wire = try #require(try conversationRecord("006").objectValue)
        var frame = try #require(wire["frame"]?.objectValue)
        frame["payload"] = .object(["kind": .string("deltas"), "deltas": .array([
            .object(["op": .string("state.updated"), "patch": .object([
                "meta": .object(["title": .string("Refonte"), "titleSource": .string("custom")]),
            ])]),
        ])])
        wire["frame"] = .object(frame)
        await server.emit(conversationEvent, .object(wire))
        _ = try await eventually { model.title == "Refonte" ? true : nil }
    }

    @Test func envoiRefuseAffiche() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object([
                "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("failed"),
                "reasonCode": .string("provider.notInRegistry"), "revisionAtDecision": .number(9),
            ])
        }
        let model = try await readyModel(server)
        #expect(await model.send("bonjour") == .failed)
        #expect(model.commandError == "Modèle indisponible sur l'hôte : choisis-en un autre.")
        model.dismissCommandError()
        #expect(model.commandError == nil)
        #expect(await model.send("   ") == .failed)                          // rien à envoyer
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").count == 1)
    }

    @Test func stopViseLExecutionAuPremierPlan() async throws {
        let server = try await conversationServer()
        let frame = try initialConversationFrame { snapshot in
            snapshot["control"] = .object([
                "phase": .string("running"), "canStop": .bool(true), "stopState": .string("stoppable"),
                "activeWorks": .array([
                    .object(["kind": .string("compact"), "startedAt": .number(1)]),
                    .object(["kind": .string("primaryTurn"), "foregroundExecutionId": .string("exec-7"), "startedAt": .number(1)]),
                ]),
            ])
        }
        let model = try await readyModel(server, frame: frame)
        #expect(model.canStop)
        await model.stopTurn()
        let command = try #require(await server.calls(to: "zcode-agent.sendConversationCommandV4").first)
        #expect(command["envelope"]?["type"] == .string("stop"))
        #expect(command["envelope"]?["payload"] == .object(["expectedForegroundExecutionId": .string("exec-7")]))
    }

    @Test func historiquePagine() async throws {
        let server = try await conversationServer()
        let page = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        await server.on("zcode-agent.conversationRowsRangeV4") { _ in page }
        let frame = try initialConversationFrame { snapshot in
            // Fenêtre réduite aux deux dernières lignes : les lignes 1 et 2 restent à charger.
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array((rows["window"]?.arrayValue ?? []).filter { ($0["rowId"]?.numberValue ?? 0) >= 3 })
            snapshot["rows"] = .object(rows)
        }
        let model = try await readyModel(server, frame: frame)
        #expect(model.hasOlderRows)
        await model.loadOlder()
        _ = try await eventually { model.snapshot?.rows.map(\.rowId) == [1, 2, 3, 4] ? true : nil }
        #expect(model.hasOlderRows == false)
        #expect(model.loadingOlder == false)
        let call = try #require(await server.calls(to: "zcode-agent.conversationRowsRangeV4").first)
        #expect(call["beforeRowId"] == .number(3))
        #expect(call["limit"] == .number(60))
        #expect(call["sessionId"] == .string(pongSession))
    }

    @Test func echecDeLHistoriqueSignaleEtSeRetente() async throws {
        struct Indisponible: Error {}
        let server = try await conversationServer()
        let page = try Fixtures.recorded("v3.15.1/conversation/005-result-zcode-agent.conversationRowsRangeV4.json")
        await server.on("zcode-agent.conversationRowsRangeV4") { _ in throw Indisponible() }
        let frame = try initialConversationFrame { snapshot in
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array((rows["window"]?.arrayValue ?? []).filter { ($0["rowId"]?.numberValue ?? 0) >= 3 })
            snapshot["rows"] = .object(rows)
        }
        let model = try await readyModel(server, frame: frame)
        #expect(model.olderRowsFailed == false)
        await model.loadOlder()
        #expect(model.olderRowsFailed)                                       // page en échec : signalé à l'écran
        #expect(model.hasOlderRows)
        await server.on("zcode-agent.conversationRowsRangeV4") { _ in page }
        await model.loadOlder()                                              // « Réessayer »
        _ = try await eventually { model.snapshot?.rows.map(\.rowId) == [1, 2, 3, 4] ? true : nil }
        #expect(model.olderRowsFailed == false)
    }

    @Test func quitterLEcranFermeLAbonnement() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        await model.stop()
        _ = try await eventually {
            let unsubscribed = await server.calls(to: "zcode-agent.unsubscribeConversationV4").count
            let listeners = await server.listenerCount(conversationEvent)
            return unsubscribed == 1 && listeners == 0 ? true : nil
        }
        #expect(model.phase == .idle)
        #expect(model.turnCount == 1)                                        // dernier état gardé pour le retour
        await model.startIfNeeded()                                          // retour sur l'écran
        #expect(await server.calls(to: "zcode-agent.subscribeConversationV4").count == 2)
    }

    @Test func perteDeConnexionReprend() async throws {
        let first = try await conversationServer()
        let second = try await conversationServer()
        let servers = ServerQueue([first, second])
        let model = makeConversation(servers)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        first.transport.finish()                                             // Mac en veille
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.phase == .ready && servers.opened == 2 ? true : nil }
        let ids = model.snapshot?.rows.map(\.rowId) ?? []
        #expect(ids == [1, 2, 3, 4])                                         // aucune ligne en double
    }

    /// La reprise automatique est déjà en file quand l'écran se ferme : elle ne doit pas rouvrir d'abonnement.
    @Test func quitterJusteApresUnePerteNeRouvrePasLAbonnement() async throws {
        let first = try await conversationServer()
        let second = try await conversationServer()
        let servers = ServerQueue([first, second])
        let model = makeConversation(servers)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        // `onChange` s'exécute pendant l'écriture de `phase = .failed`, donc avant que la reprise soit mise en file :
        // le `stop()` qu'il lance passe devant elle sur l'acteur principal.
        let stopped = Recorder<Bool>()
        withObservationTracking({ _ = model.phase }, onChange: {
            Task { @MainActor in
                await model.stop()
                stopped.append(true)
            }
        })
        first.transport.finish()                                             // Mac en veille
        _ = try await eventually { stopped.all.isEmpty ? nil : true }
        try await Task.sleep(for: .milliseconds(100))                        // laisse passer une reprise tardive
        #expect(servers.opened == 1)
        #expect(await second.listenerCount(conversationEvent) == 0)
        #expect(await second.calls(to: "zcode-agent.subscribeConversationV4").isEmpty)
    }

    /// Un hôte injoignable ou lent pour le catalogue ne retarde pas l'abonnement de la conversation.
    @Test func ouvertureSansAttendreLeCatalogue() async throws {
        let server = try await conversationServer()
        let slowCatalog = ModelCatalog(connection: HostConnection(
            host: testHost, endpoint: testEndpoint,
            dependencies: makeDependencies(servers: ServerQueue([]), serverInfoDelay: .seconds(10))))
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, catalog: slowCatalog)
        let starting = Task { await model.start() }
        try await emitConversation(server, initialConversationFrame())          // 5 s max : le catalogue en demande 10
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(slowCatalog.view == nil)
        await starting.value
    }

    @Test func echecDAbonnementPuisRelance() async throws {
        let server = try await conversationServer()
        let ack = try conversationRecord("003")
        await server.on("zcode-agent.subscribeConversationV4") { _ in throw CheckError("indisponible") }
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        await server.on("zcode-agent.subscribeConversationV4") { _ in ack }
        await model.refresh()                                                   // « Réessayer »
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.turnCount == 1)
    }

    @Test func autoriteDuCatalogueDesSkills() async throws {
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]))
        #expect(model.skillsCatalogSessionId == nil)                         // pas encore de snapshot
        await model.start()
        try await emitConversation(server, initialConversationFrame())       // PONG : 4 lignes
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.skillsCatalogSessionId == pongSession)

        // Session vide (aucune ligne) : le catalogue est celui du projet.
        let emptyServer = try await conversationServer()
        let empty = makeConversation(ServerQueue([emptyServer]))
        await empty.start()
        try await emitConversation(emptyServer, initialConversationFrame { snapshot in
            var rows = try #require(snapshot["rows"]?.objectValue)
            rows["window"] = .array([])
            rows["totalCount"] = .number(0)
            snapshot["rows"] = .object(rows)
        })
        _ = try await eventually { empty.phase == .ready ? true : nil }
        #expect(empty.skillsCatalogSessionId == nil)
    }
}

private extension ChatEntry {
    /// État du tour si cette entrée est son pied.
    var turnState: TurnState? {
        if case .turnFooter(let header) = content { header.state } else { nil }
    }
}
