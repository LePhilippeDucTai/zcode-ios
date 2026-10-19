import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

func snapshotJSON(_ wire: JSONValue) -> JSONValue? { wire["frame"]?["payload"]?["snapshot"] }

func frameDeltas(_ wire: JSONValue) -> [ConversationDelta] {
    (wire["frame"]?["payload"]?["deltas"]?.arrayValue ?? []).map(ConversationDelta.init(json:))
}

func record(_ folder: String, _ prefix: String) throws -> JSONValue {
    let match = try #require(try Fixtures.records(in: "v3.15.1/\(folder)").first { $0.file.hasPrefix(prefix) })
    return match.value
}

struct ConversationSnapshotTests {
    func pongSnapshot() throws -> ConversationSnapshot {
        try ConversationSnapshot(json: #require(snapshotJSON(record("send-text", "004"))))
    }

    @Test func snapshotReel() throws {
        let snapshot = try pongSnapshot()
        #expect(snapshot.sessionId == "sess_45199523-12a0-4928-92e6-ff082723da62")
        #expect(snapshot.logEpoch == "mv6j6gf9-m0d4m1jc")
        #expect(snapshot.revision == 9)
        #expect(snapshot.rows.map(\.rowId) == [1, 2, 3, 4])
        #expect(snapshot.totalCount == 4)
        #expect(snapshot.firstRowId == 1)
        #expect(snapshot.control?.phase == .completedSuccess)
        #expect(snapshot.control?.isBusy == false)
        #expect(snapshot.config?.model == "GLM-5.3")
        #expect(snapshot.config?.thoughtLevels == ["low", "high", "max"])
        #expect(snapshot.config?.modelSelection == ModelSelection(
            providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3", reasoningLevel: "max"))
        #expect(snapshot.meta?.title == "Demande de réponse PONG")
        #expect(snapshot.availability["pauseGoal"]?.allowed == false)
        #expect(snapshot.availability["switchModelConfig"]?.allowed == true)
        #expect(snapshot.inputRouting?.mode == "startNow")
        #expect(snapshot.pendingInteractions.isEmpty)
        #expect(snapshot.goal == nil)
        #expect(snapshot.queue?.items.isEmpty == true)
        #expect(snapshot.usage?.maxTokens == 1_000_000)
    }

    @Test func rejeuDUnTourAvecOutil() throws {
        var snapshot = try pongSnapshot()
        for prefix in ["006", "007", "008", "009"] {
            snapshot.apply(frameDeltas(try record("send-text", prefix)))
        }
        #expect(snapshot.revision == 24)
        #expect(snapshot.control?.phase == .completedSuccess)
        #expect(snapshot.rows.map(\.rowId) == Array(1...10))
        #expect(snapshot.totalCount == 10)
        guard case .toolCall(let call) = snapshot.row(id: 8)?.content else { Issue.record("outil attendu"); return }
        #expect(call.status == .success)
        guard case .assistantText(let answer) = snapshot.row(id: 10)?.content else { Issue.record("réponse attendue"); return }
        #expect(answer.text.hasPrefix("Le dossier `/Users/me/claude`"))
    }

    @Test func streamingDeTexteCoherent() throws {
        var snapshot = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text-long", "003"))))
        var seen: [String] = []
        for prefix in ["006", "007", "008", "009", "010", "011", "012", "013"] {
            snapshot.apply(frameDeltas(try record("send-text-long", prefix)))
            if case .assistantText(let answer) = snapshot.row(id: 14)?.content { seen.append(answer.text) }
        }
        guard case .assistantText(let final) = snapshot.row(id: 14)?.content else { Issue.record("réponse attendue"); return }
        #expect(final.state == .complete)
        #expect(final.text.hasPrefix("## Le protocole WebSocket"))
        #expect(Set(seen).count == 7)                              // le texte a grandi par row.delta
        #expect(seen.allSatisfy { final.text.hasPrefix($0) })      // chaque étape est un préfixe du texte final
        #expect(snapshot.revision == 31)
    }

    @Test func nullExpliciteEffaceCleAbsenteConserve() throws {
        var snapshot = try pongSnapshot()
        let goal: JSONValue = .object([
            "objective": .string("Tests verts"), "status": .string("active"), "iteration": .number(2), "verifications": .array([]),
        ])
        snapshot.apply(.stateUpdated(["goal": goal]))
        #expect(snapshot.goal?.objective == "Tests verts")
        #expect(snapshot.goal?.status == .active)
        snapshot.apply(.stateUpdated(["revision": .number(10)]))
        #expect(snapshot.goal?.objective == "Tests verts")         // clé absente : conservée
        #expect(snapshot.revision == 10)
        snapshot.apply(.stateUpdated(["goal": .null]))
        #expect(snapshot.goal == nil)                              // null explicite : effacée
        #expect(snapshot.state["goal"] == .null)
    }

    @Test func remplacementCleParCleSansFusion() throws {
        var snapshot = try pongSnapshot()
        snapshot.apply(.stateUpdated(["control": .object(["phase": .string("running")])]))
        #expect(snapshot.control?.phase == .running)
        #expect(snapshot.control?.canStop == nil)                  // l'ancien objet n'est pas fusionné
        #expect(snapshot.control?.isBusy == true)
    }

    @Test func upsertDUneLigneNonChargeeIgnore() throws {
        var snapshot = try pongSnapshot()
        let ghost = try #require(ConversationRow(json: .object(["rowId": .number(999), "kind": .string("userInput"), "text": .string("x")])))
        snapshot.apply(.rowUpserted(ghost))
        #expect(snapshot.rows.map(\.rowId) == [1, 2, 3, 4])
        #expect(snapshot.totalCount == 4)
    }

    @Test func suppressionDepuisUneLigne() throws {
        var snapshot = try pongSnapshot()
        snapshot.apply(.rowRemoved(fromRowId: 3))
        #expect(snapshot.rows.map(\.rowId) == [1, 2])
        #expect(snapshot.totalCount == 2)
        #expect(snapshot.firstRowId == 1)
        snapshot.apply(.rowRemoved(fromRowId: 1))
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.totalCount == 0)
        #expect(snapshot.firstRowId == nil)
        let row = try #require(ConversationRow(json: .object(["rowId": .number(7), "kind": .string("userInput"), "text": .string("y")])))
        snapshot.apply(.rowAppended(row))
        #expect(snapshot.firstRowId == 7)
        #expect(snapshot.totalCount == 1)
    }

    @Test func ajoutDUneLigneDejaPresenteRemplace() throws {
        var snapshot = try pongSnapshot()
        let replay = try #require(ConversationRow(json: .object(["rowId": .number(4), "kind": .string("assistantText"),
                                                                  "text": .string("PONG!"), "state": .string("complete")])))
        snapshot.apply(.rowAppended(replay))
        #expect(snapshot.rows.map(\.rowId) == [1, 2, 3, 4])        // pas de doublon d'identifiant
        #expect(snapshot.totalCount == 4)
        guard case .assistantText(let answer) = snapshot.row(id: 4)?.content else { Issue.record("réponse"); return }
        #expect(answer.text == "PONG!")
    }

    @Test func deltaSurLigneAbsenteIgnore() throws {
        var snapshot = try pongSnapshot()
        let before = snapshot
        snapshot.apply(.rowDelta(rowId: 42, path: .text, append: "x"))
        #expect(snapshot == before)
    }

    @Test func opInconnuIgnoreLesAutresAppliques() throws {
        var snapshot = try pongSnapshot()
        let deltas = [
            ConversationDelta(json: .object(["op": .string("workflowRun.updated"), "runId": .string("r")])),
            ConversationDelta(json: .object(["op": .string("row.delta"), "rowId": .string("pas un entier")])),
            ConversationDelta(json: .object(["op": .string("state.updated"), "patch": .object(["revision": .number(10)])])),
        ]
        #expect(deltas[0] == .unknown(op: "workflowRun.updated", raw: .object(["op": .string("workflowRun.updated"), "runId": .string("r")])))
        guard case .unknown(op: "row.delta", _) = deltas[1] else { Issue.record("delta mal formé attendu"); return }
        snapshot.apply(deltas)
        #expect(snapshot.revision == 10)
    }

    @Test func snapshotAvecLigneInconnue() throws {
        var json = try #require(snapshotJSON(record("send-text", "004"))?.objectValue)
        var rows = try #require(json["rows"]?.objectValue)
        var window = try #require(rows["window"]?.arrayValue)
        window.append(.object(["rowId": .number(5), "kind": .string("hologram"), "turnId": .string("t")]))
        rows["window"] = .array(window)
        json["rows"] = .object(rows)
        let snapshot = try ConversationSnapshot(json: .object(json))
        #expect(snapshot.rows.count == 5)
        #expect(snapshot.row(id: 5)?.content == .unsupported)
        #expect(snapshot.row(id: 5)?.kind.rawValue == "hologram")
    }

    @Test func snapshotStructurellementInvalide() throws {
        var json = try #require(snapshotJSON(record("send-text", "004"))?.objectValue)
        json["rows"] = nil
        #expect(throws: V4DecodingError.missingField("rows")) { try ConversationSnapshot(json: .object(json)) }
        json = try #require(snapshotJSON(record("send-text", "004"))?.objectValue)
        json["sessionId"] = nil
        #expect(throws: V4DecodingError.missingField("sessionId")) { try ConversationSnapshot(json: .object(json)) }
        #expect(throws: V4DecodingError.self) { try ConversationSnapshot(json: .string("x")) }
    }

    @Test func interactionsEnAttente() throws {
        var snapshot = try pongSnapshot()
        let permission: JSONValue = .object([
            "interactionId": .string("perm_1"), "kind": .string("permission"), "anchorRowId": .number(6), "createdAt": .number(1),
            "payload": .object([
                "kind": .string("permission"), "toolCallId": .string("call_1"), "toolName": .string("Write"),
                "summary": .string("Tool has side effects and requires approval"), "detail": .object([:]),
                "options": .array([
                    .object(["optionId": .string("allowOnce"), "label": .string("Allow once"), "kind": .string("allowOnce")]),
                    .object(["optionId": .string("allowAlways"), "label": .string("Always allow in this project"), "kind": .string("allowAlways")]),
                    .object(["optionId": .string("deny"), "label": .string("Deny"), "kind": .string("deny")]),
                ]),
            ]),
        ])
        let question: JSONValue = .object([
            "interactionId": .string("ask_1"), "kind": .string("userInput"), "anchorRowId": .null, "createdAt": .number(2),
            "payload": .object([
                "kind": .string("userInput"), "prompt": .string("Quel style ?"), "freeText": .bool(true),
                "questions": .array([.object([
                    "question": .string("Quel style ?"), "header": .string("Style"), "multiSelect": .bool(false),
                    "options": .array([.object(["value": .string("a"), "label": .string("Sobre"), "description": .string("Peu de couleurs")])]),
                ])]),
            ]),
        ])
        let review: JSONValue = .object([
            "interactionId": .string("hook_1"), "kind": .string("workspaceHookReview"), "anchorRowId": .null,
            "createdAt": .number(3), "payload": .object(["kind": .string("workspaceHookReview")]),
        ])
        let broken: JSONValue = .object(["kind": .string("permission")])
        snapshot.apply(.stateUpdated(["pendingInteractions": .array([permission, question, review, broken])]))
        let interactions = snapshot.pendingInteractions
        #expect(interactions.map(\.interactionId) == ["perm_1", "ask_1", "hook_1"])
        guard case .permission(let request) = interactions[0].payload else { Issue.record("permission attendue"); return }
        #expect(request.toolName == "Write")
        #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .deny])
        #expect(interactions[0].anchorRowId == 6)
        guard case .userInput(let ask) = interactions[1].payload else { Issue.record("question attendue"); return }
        #expect(ask.questions?.first?.options.first?.label == "Sobre")
        #expect(interactions[1].anchorRowId == nil)
        #expect(interactions[2].kind == .workspaceHookReview)
        #expect(interactions[2].payload == .unsupported)
    }

    @Test func insertionDeLignesPlusAnciennes() throws {
        var snapshot = try pongSnapshot()
        snapshot.apply(.rowRemoved(fromRowId: 1))                   // fenêtre vide, on recharge l'historique
        let page = try #require(snapshotJSON(record("send-text", "004"))?["rows"]?["window"]?.arrayValue)
            .compactMap(ConversationRow.init(json:))
        snapshot.insertOlderRows(Array(page[2...]))
        snapshot.insertOlderRows(page)                              // chevauchement : pas de doublon
        #expect(snapshot.rows.map(\.rowId) == [1, 2, 3, 4])
    }
}
