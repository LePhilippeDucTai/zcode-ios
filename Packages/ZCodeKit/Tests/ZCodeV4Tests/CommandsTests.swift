import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct CommandsTests {
    static let instant = Date(timeIntervalSince1970: 1_791_886_864.067)
    let builder = CommandBuilder(clientId: "client-test", clock: { CommandsTests.instant })
    let base = CommandBase(revision: 9, logEpoch: "mv6j6gf9-m0d4m1jc")

    @Test func envoyerUnGoal() {
        let envelope = builder.sendGoal(sessionId: "s", objective: "tests verts", displayText: "/goal tests verts",
                                        mode: "build", planEnabled: false,
                                        heldQueue: .init(.keepQueueAndSend, expectedItemIds: ["q1"]))
        #expect(envelope.type == .sendGoalCommand && envelope.baseRevision == nil)
        #expect(envelope.payload == .object([
            "text": .string("tests verts"), "displayText": .string("/goal tests verts"), "mode": .string("build"),
            "planEnabled": .bool(false), "heldQueueDisposition": .string("keepQueueAndSend"),
            "expectedHeldQueueItemIds": .array([.string("q1")]),
        ]))
        #expect(builder.sendGoal(sessionId: "s", objective: "x", displayText: nil).payload == .object(["text": .string("x")]))
    }

    @Test func relancerUnTour() {
        let envelope = builder.retryTurn(sessionId: "s", target: RowTarget(rowId: 12, entityId: "e"),
                                         base: CommandBase(revision: 7, logEpoch: "ep"))
        #expect(envelope.type == .retryTurn && envelope.baseRevision == 7 && envelope.baseLogEpoch == "ep")
        #expect(envelope.sessionId == "s")
        #expect(envelope.payload == .object(["target": .object(["rowId": .number(12), "entityId": .string("e")])]))
    }

    @Test func repartirDUneReponse() {
        let envelope = builder.forkAssistant(sessionId: "s", target: RowTarget(rowId: 4, entityId: "e"), base: base)
        #expect(envelope.type == .forkAssistant && envelope.baseRevision == 9 && envelope.baseLogEpoch == "mv6j6gf9-m0d4m1jc")
        #expect(envelope.payload == .object(["target": .object(["rowId": .number(4), "entityId": .string("e")])]))
    }

    @Test func actionsDUneLigne() throws {
        let row = try #require(ConversationRow(json: .object([
            "rowId": .number(4), "kind": .string("assistantText"), "text": .string("x"),
            "actions": .object(["canFork": .bool(true), "canRetry": .bool(true)]),
        ])))
        #expect(row.actions == RowActions(canRetry: true, canEdit: false, canFork: true, canRewindFiles: false))
        let bare = try #require(ConversationRow(json: .object(["rowId": .number(5), "kind": .string("assistantText"),
                                                               "actions": .string("?")])))
        #expect(bare.actions == RowActions(canRetry: false, canEdit: false, canFork: false, canRewindFiles: false))
    }

    @Test func createSessionEcritUnSessionIdNull() throws {
        let command = builder.createSession(workspaceId: "/Users/me/claude")
        let json = try #require(command.json.objectValue)
        #expect(json.keys.contains("sessionId"))
        #expect(json["sessionId"] == .null)
        #expect(json["type"] == .string("createSession"))
        #expect(json["clientId"] == .string("client-test"))
        #expect(json["payload"] == .object(["workspaceId": .string("/Users/me/claude")]))
        #expect(json["issuedAt"] == .number(1_791_886_864_067))
        #expect(json["baseRevision"] == nil)
        #expect(UUIDv7.timestamp(of: command.commandId) == Self.instant)
    }

    @Test func createSessionAvecUnModeDemande() throws {
        let plain = builder.createSession(workspaceId: "/w")
        #expect(plain.payload == .object(["workspaceId": .string("/w")]))           // sans réglage : inchangé
        let command = builder.createSession(workspaceId: "/w", mode: "build", planEnabled: true)
        #expect(command.payload == .object([
            "workspaceId": .string("/w"),
            "config": .object(["mode": .string("build"), "planEnabled": .bool(true)]),
        ]))
        #expect(command.baseRevision == nil)
    }

    @Test func sendTextLaisseLeServeurChoisir() {
        let command = builder.sendText(
            sessionId: "sess_1", text: "Bonjour 🌍",
            modelSelection: ModelSelection(providerId: "new-provider", modelId: "mistral-large-4", reasoningLevel: "none"),
            mode: "build", planEnabled: false)
        #expect(command.json["sessionId"] == .string("sess_1"))
        // Pas de `requestedDelivery` : `startNow` explicite interromprait le tour en cours.
        #expect(command.payload == .object([
            "text": .string("Bonjour 🌍"), "inputOrigin": .string("mobile"),
            "modelSelection": .object([
                "providerId": .string("new-provider"), "modelId": .string("mistral-large-4"),
                "options": .object(["reasoningLevel": .string("none")]),
            ]),
            "mode": .string("build"), "planEnabled": .bool(false),
        ]))
        let queued = builder.sendText(sessionId: "sess_1", text: "ensuite", delivery: .queue)
        #expect(queued.payload["requestedDelivery"] == .string("queue"))
        #expect(queued.payload["modelSelection"] == nil)
        #expect(queued.payload["planEnabled"] == nil)
    }

    @Test func sendTextAvecChoixDeFileEnPause() {
        let command = builder.sendText(
            sessionId: "sess_1", text: "on repart",
            heldQueue: .init(.keepQueueAndSend, expectedItemIds: ["q1", "q2"]))
        #expect(command.payload["heldQueueDisposition"] == .string("keepQueueAndSend"))
        #expect(command.payload["expectedHeldQueueItemIds"] == .array([.string("q1"), .string("q2")]))
    }

    @Test func commandesDeFileAvecBase() {
        let delete = builder.deleteQueueItem(sessionId: "s", queueItemId: "q1", base: base)
        #expect(delete.type == .deleteQueueItem)
        #expect(delete.baseRevision == 9)
        #expect(delete.payload == .object(["queueItemId": .string("q1")]))
        let now = builder.sendQueuedNow(sessionId: "s", queueItemId: "q2", base: base)
        #expect(now.type == .sendQueuedNow)
        #expect(now.payload == .object(["queueItemId": .string("q2")]))
        let drain = builder.setAutoDrain(sessionId: "s", autoDrain: true, base: base)
        #expect(drain.type == .setAutoDrain)
        #expect(drain.baseRevision == 9)
        #expect(drain.payload == .object(["autoDrain": .bool(true)]))
    }

    @Test func accuseReelDonneLaLivraison() throws {
        let ack = try CommandAck(json: Fixtures.recorded("v3.15.1/send-text/005-result-zcode-agent.sendConversationCommandV4.json"))
        #expect(ack.isAccepted)
        #expect(ack.result?.type == "inputAccepted")
        #expect(ack.result?.delivery == "startNow")
    }

    @Test func elementsDeFileLusAvecLeurEtat() throws {
        let item: (String, String, String) -> JSONValue = { id, admitted, state in
            .object([
                "queueItemId": .string(id), "kind": .string("sendText"), "text": .string("texte \(id)"),
                "delivery": .object(["requested": .string("auto"), "admitted": .string(admitted)]),
                "dispatch": .object(["state": .string(state)]), "attachments": .array([]),
            ])
        }
        var snapshot = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text", "004"))))
        snapshot.apply(.stateUpdated(["queue": .object([
            "autoDrain": .bool(false), "pauseReason": .string("stopped"),
            "items": .array([item("q1", "queue", "queued"), item("q2", "guide", "queued"), item("q3", "queue", "promoting")]),
        ])]))
        let items = try #require(snapshot.queue?.items)
        #expect(items.map(\.isGuide) == [false, true, false])
        #expect(items.map(\.isLocked) == [false, false, true])
        #expect(snapshot.queue?.pauseReason == "stopped")
    }

    @Test func elementDeFileDeTypeInattenduConserve() throws {
        // `delivery` ou `dispatch` d'un autre type ne doit pas faire disparaître l'élément (sinon la file attendue serait incomplète).
        var snapshot = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text", "004"))))
        snapshot.apply(.stateUpdated(["queue": .object([
            "autoDrain": .bool(false),
            "items": .array([
                .object(["queueItemId": .string("q1"), "text": .string("a"), "delivery": .string("queue"),
                         "dispatch": .number(3)]),
                .object(["queueItemId": .string("q2"), "text": .string("b"),
                         "delivery": .object(["admitted": .string("guide")]), "dispatch": .object(["state": .string("promoting")])]),
            ]),
        ])]))
        let items = try #require(snapshot.queue?.items)
        #expect(items.map(\.queueItemId) == ["q1", "q2"])
        #expect(items[0].delivery == nil && items[0].dispatch == nil)
        #expect(items[0].isGuide == false && items[0].isLocked == false)
        #expect(items[1].isGuide && items[1].isLocked)
    }

    @Test func commandesCASExigentUneBase() throws {
        #expect(throws: CommandBuildError.missingBaseRevision(.pauseGoal)) {
            try builder.envelope(.pauseGoal, sessionId: "s", payload: [:])
        }
        #expect(throws: CommandBuildError.missingBaseRevision(.retryTurn)) {
            try builder.envelope(.retryTurn, sessionId: "s", payload: [:])
        }
        #expect(throws: CommandBuildError.missingBaseLogEpoch(.setHighspeedMetrics)) {
            try builder.envelope(.setHighspeedMetrics, sessionId: "s", payload: [:])
        }
        let retry = try builder.envelope(.retryTurn, sessionId: "s",
                                         payload: ["target": RowTarget(rowId: 4, entityId: "e").json], base: base)
        #expect(retry.json["baseRevision"] == .number(9))
        #expect(retry.json["baseLogEpoch"] == .string("mv6j6gf9-m0d4m1jc"))
        let model = builder.switchModelConfig(sessionId: "s", provider: "new-provider", model: "mistral-large-4", thought: "none", base: base)
        #expect(model.baseRevision == 9)
        #expect(model.payload == .object(["provider": .string("new-provider"), "model": .string("mistral-large-4"), "thought": .string("none")]))
        #expect(builder.pauseGoal(sessionId: "s", base: base).payload == .object([:]))
        #expect(builder.switchCollaborationMode(sessionId: "s", mode: "plan", base: base).payload == .object(["mode": .string("plan")]))
    }

    @Test func autresCommandesDeLaV1() {
        #expect(builder.resolveInteraction(sessionId: "s", interactionId: "perm_1", answer: .init(optionId: "allowOnce")).payload == .object([
            "interactionId": .string("perm_1"), "answer": .object(["optionId": .string("allowOnce")]),
        ]))
        #expect(builder.resolveInteraction(sessionId: "s", interactionId: "ask_1", answer: .init(freeText: "Sobre")).payload["answer"]
            == .object(["freeText": .string("Sobre")]))
        #expect(builder.stop(sessionId: "s", expectedForegroundExecutionId: "exec_1").payload
            == .object(["expectedForegroundExecutionId": .string("exec_1")]))
        #expect(builder.stop(sessionId: "s").payload == .object([:]))
        #expect(builder.renameSession(sessionId: "s", title: "Nouveau titre").payload == .object(["title": .string("Nouveau titre")]))
        #expect(builder.deleteSession(sessionId: "s").type == .deleteSession)
        #expect(builder.compact(sessionId: "s").baseRevision == nil)
    }

    @Test func uuidV7() throws {
        let uuid = UUIDv7.make(at: Self.instant)
        #expect(uuid.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
        #expect(uuid.hasPrefix("01a134c7-aec3"))                   // 1791886864067 ms = 0x01A134C7AEC3
        #expect(UUIDv7.timestamp(of: uuid) == Self.instant)
        #expect(UUIDv7.make(at: Self.instant) != uuid)            // partie aléatoire
        #expect(UUIDv7.make(at: Self.instant.addingTimeInterval(0.001)) > uuid)   // ordonnés dans le temps
        #expect(UUIDv7.timestamp(of: "pas-un-uuid") == nil)
    }

    @Test func clientIdPersistant() {
        let storage = InMemoryClientIDStorage()
        let first = ClientIdentity.clientId(storage: storage)
        #expect(first.hasPrefix("client-"))
        #expect(UUIDv7.timestamp(of: String(first.dropFirst("client-".count))) != nil)
        #expect(storage.load() == first)
        #expect(ClientIdentity.clientId(storage: storage) == first)
    }

    @Test func accusesReels() throws {
        let sent = try CommandAck(json: Fixtures.recorded("v3.15.1/send-text/005-result-zcode-agent.sendConversationCommandV4.json"))
        #expect(sent.status == .accepted)
        #expect(sent.isAccepted)
        #expect(sent.revisionAtDecision == 9)
        #expect(sent.result?.type == "inputAccepted")
        let created = try CommandAck(json: .object([
            "commandId": .string("bab0196e-b2dd-420e-82e4-4b768a229c2b"), "memoryEnabled": .bool(true),
            "result": .object(["sessionId": .string("sess_db05bd4a-d958-4919-b723-8a2de567689c"), "type": .string("createSession")]),
            "revisionAtDecision": .number(0), "status": .string("accepted"),
        ]))
        #expect(created.result?.sessionId == "sess_db05bd4a-d958-4919-b723-8a2de567689c")
        let refused = try CommandAck(json: .object([
            "commandId": .string("c"), "status": .string("stale"), "reasonCode": .string("guard.revisionMismatch"), "revisionAtDecision": .number(12),
        ]))
        #expect(!refused.isAccepted)
        #expect(refused.reasonCode == "guard.revisionMismatch")
        let future = try CommandAck(json: .object(["commandId": .string("c"), "status": .string("deferred")]))
        #expect(future.status.rawValue == "deferred")
        #expect(future.revisionAtDecision == nil)
        #expect(throws: V4DecodingError.missingField("commandId")) { try CommandAck(json: .object(["status": .string("accepted")])) }
    }

    @Test func requeteDeCommandes() throws {
        let command = builder.createSession(workspaceId: "/w")
        #expect(command.key.json == .object(["sessionId": .null, "commandId": .string(command.commandId)]))
        let items = try CommandsQuery.parse(.object(["results": .array([
            .object(["key": .object(["sessionId": .null, "commandId": .string("c1")]), "result": .string("unknown")]),
            .object(["key": .object(["sessionId": .string("s"), "commandId": .string("c2")]),
                     "result": .object(["commandId": .string("c2"), "status": .string("accepted"), "revisionAtDecision": .number(3)])]),
        ])]))
        #expect(items.map(\.key) == [CommandKey(sessionId: nil, commandId: "c1"), CommandKey(sessionId: "s", commandId: "c2")])
        #expect(items[0].result == .unknown)
        guard case .known(let ack) = items[1].result else { Issue.record("accusé attendu"); return }
        #expect(ack.isAccepted)
    }

    @Test func reponseAvecActionEtContenu() {
        let answer = InteractionAnswer(action: .accept, content: [
            "answers": .object(["Quel style ?": .string("Sobre")]), "answer": .string("Sobre"),
        ])
        let command = builder.resolveInteraction(sessionId: "s", interactionId: "ask_1", answer: answer)
        #expect(command.type == .resolveInteraction)
        #expect(command.baseRevision == nil)
        #expect(command.payload == .object([
            "interactionId": .string("ask_1"),
            "answer": .object([
                "action": .string("accept"),
                "content": .object(["answers": .object(["Quel style ?": .string("Sobre")]), "answer": .string("Sobre")]),
            ]),
        ]))
        #expect(builder.resolveInteraction(sessionId: "s", interactionId: "ask_1", answer: .decline).payload["answer"]
            == .object(["action": .string("decline")]))
        #expect(InteractionAnswer(optionId: "deny", freeText: "Utilise la corbeille").json
            == .object(["optionId": .string("deny"), "freeText": .string("Utilise la corbeille")]))
    }

    @Test func suspensionDuCompteARebours() {
        let command = builder.snoozeAutoResolution(sessionId: "s", interactionId: "ask_1")
        #expect(command.type == .snoozeInteractionAutoResolution)
        #expect(command.json["type"] == .string("snoozeInteractionAutoResolution"))
        #expect(command.payload == .object(["interactionId": .string("ask_1")]))
        #expect(command.baseRevision == nil)
        #expect(!CommandType.requiringBaseRevision.contains(.snoozeInteractionAutoResolution))
    }
}
