import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ChatTimelineTests {
    func row(_ rowId: Int, _ kind: String, turn: String? = "t1", _ fields: [String: JSONValue] = [:]) throws -> ConversationRow {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        if let turn { object["turnId"] = .string(turn) }
        return try #require(ConversationRow(json: .object(object)))
    }

    @Test func conversationReelleEnEntrees() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text/004-event-zcode-agent.onDynamicConversationFrame.json")
        let snapshot = try ConversationSnapshot(json: #require(wire["frame"]?["payload"]?["snapshot"]))
        let entries = ChatTimeline.entries(from: snapshot.rows)
        #expect(entries.count == 4)
        #expect(entries.map(\.id).dropLast() == [2, 3, 4])                  // l'en-tête de tour n'est pas une ligne
        #expect(entries.map(\.startsTurn) == [true, false, false, false])
        guard case .item(.user(_, let input)) = entries[0].content, case .item(.assistant(_, let answer)) = entries[2].content,
              case .turnFooter(let header) = entries[3].content else {
            Issue.record("question, réponse puis pied attendus"); return
        }
        #expect(input.text == "réponds moi PONG")
        #expect(answer.text == "PONG")
        #expect(header.state == .completedSuccess)
        #expect(header.summaryLabel == "Terminé en 3 s")
    }

    @Test func lignesMasqueesEtCartesGeneriques() throws {
        let rows = try [
            row(1, "turnHeader", ["state": .string("running")]),
            row(2, "userInput", ["text": .string("salut")]),
            row(3, "reasoning", ["text": .string("  "), "state": .string("complete")]),          // vide : masqué
            row(4, "hookInvocation", ["hookName": .string("lint")]),                              // masqué
            row(5, "timelineMarker", ["marker": .object(["type": .string("goalSet"), "objective": .string("x")])]),
            row(6, "timelineMarker", ["marker": .object([
                "type": .string("modelChange"), "fromProvider": .string("a"), "fromModel": .string("GLM-5.3"),
                "toProvider": .string("b"), "toModel": .string("mistral-large-4"), "toThought": .string("none"),
            ])]),
            row(7, "artifact", ["name": .string("rapport.pdf")]),
            row(8, "nouveauType", turn: nil, ["x": .number(1)]),
        ]
        let entries = ChatTimeline.entries(from: rows)
        #expect(entries.map(\.id) == [2, 6, 7, 1, 8])                      // pied du tour t1 (en-tête = ligne 1) avant la ligne 8
        #expect(entries.map(\.startsTurn) == [true, false, false, false, true])
        guard case .turnFooter(let header) = entries[3].content else { Issue.record("pied attendu"); return }
        #expect(header.summaryLabel == "En cours…")
        #expect(entries[1].content == .item(.marker(rowId: 6, label: "Modèle : GLM-5.3 → mistral-large-4")))
        guard case .item(.unsupported(_, let kind, _)) = entries[2].content,
              case .item(.unsupported(_, let other, _)) = entries[4].content else {
            Issue.record("cartes génériques attendues"); return
        }
        #expect(kind == "artifact")
        #expect(other == "nouveauType")
    }

    /// Lignes d'un même `turnId` non contiguës : a, b, a, a.
    func interleavedRows() throws -> [ConversationRow] {
        try [
            row(1, "userInput", turn: "a", ["text": .string("1")]),
            row(2, "userInput", turn: "b", ["text": .string("2")]),
            row(3, "assistantText", turn: "a", ["text": .string("3"), "state": .string("complete")]),
            row(4, "assistantText", turn: "a", ["text": .string("4"), "state": .string("complete")]),
        ]
    }

    @Test func identifiantsUniquesEtRegroupementParTour() throws {
        let entries = ChatTimeline.entries(from: try interleavedRows())
        #expect(entries.map(\.id) == [1, 2, 3, 4])
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.map(\.startsTurn) == [true, true, true, false])    // la reprise du tour « a » ouvre un nouveau groupe
        // L'en-tête et un élément ne partagent jamais un identifiant.
        let withHeader = ChatTimeline.entries(from: try [
            row(1, "turnHeader", ["state": .string("completedSuccess")]),
            row(2, "userInput", ["text": .string("x")]),
            row(3, "turnHeader", turn: "t2", ["state": .string("failed")]),
            row(4, "userInput", turn: "t2", ["text": .string("y")]),
        ])
        #expect(Set(withHeader.map(\.id)).count == withHeader.count)
        #expect(withHeader.map(\.id) == [2, 1, 4, 3])
    }

    @Test func pageAncienneAjouteeDevantNeChangePasLesIdentifiants() throws {
        // Tour coupé par la fenêtre : l'en-tête (ligne 1) et la première question sont dans la page plus ancienne.
        let turn = try [
            row(1, "turnHeader", ["state": .string("completedSuccess"), "activeMs": .number(2000)]),
            row(2, "userInput", ["text": .string("q")]),
            row(3, "toolCall", ["toolCallId": .string("c"), "toolName": .string("Bash"), "status": .string("success"), "inputText": .string("{}")]),
            row(4, "assistantText", ["text": .string("fin"), "state": .string("complete")]),
        ]
        for rows in [turn, try interleavedRows()] {
            let full = ChatTimeline.entries(from: rows)
            for cut in 1..<rows.count {
                let window = ChatTimeline.entries(from: Array(rows[cut...]))
                let windowIds = Set(window.map(\.id))
                // Les entrées déjà affichées gardent leur identifiant, dans le même ordre, quelle que soit la page chargée devant.
                #expect(full.map(\.id).filter(windowIds.contains) == window.map(\.id), "fenêtre depuis la ligne \(cut + 1)")
                #expect(Set(window.map(\.id)).count == window.count)
            }
        }
    }

    @Test func unDeltaNeChangeQueLEntreeDeSaLigne() throws {
        func rows(_ answer: String) throws -> [ConversationRow] {
            try [
                row(1, "turnHeader", ["state": .string("running")]),
                row(2, "userInput", ["text": .string("q")]),
                row(3, "toolCall", ["toolCallId": .string("c"), "toolName": .string("Bash"), "status": .string("success"), "inputText": .string("{}")]),
                row(4, "assistantText", ["text": .string(answer), "state": .string("streaming")]),
                row(5, "userInput", turn: "t2", ["text": .string("suite")]),
            ]
        }
        let before = ChatTimeline.entries(from: try rows("PO"))
        let after = ChatTimeline.entries(from: try rows("PONG"))
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.map(\.startsTurn) == after.map(\.startsTurn))
        let changed = zip(before, after).filter { $0 != $1 }.map(\.0.id)
        #expect(changed == [4])
    }

    @Test func toursSansEnTeteCharge() throws {
        // Première page d'historique pas encore chargée : le tour n'a pas d'en-tête mais reste affiché, sans pied.
        let entries = ChatTimeline.entries(from: try [
            row(10, "assistantText", turn: "ancien", ["text": .string("fin"), "state": .string("complete")]),
            row(11, "turnHeader", turn: "neuf", ["state": .string("failed")]),
            row(12, "userInput", turn: "neuf", ["text": .string("et ensuite ?")]),
        ])
        #expect(entries.map(\.id) == [10, 12, 11])
        #expect(entries.map(\.startsTurn) == [true, true, false])
        guard case .turnFooter(let header) = entries[2].content else { Issue.record("pied attendu"); return }
        #expect(header.summaryLabel == "Échec du tour")
    }

    @Test func enTeteSansLibelleNAPasDePied() throws {
        let entries = ChatTimeline.entries(from: try [
            row(1, "turnHeader", ["state": .string("pending")]),
            row(2, "userInput", ["text": .string("q")]),
        ])
        #expect(entries.map(\.id) == [2])
    }

    @Test func libellesDOutilEtDeRefus() throws {
        let tool = try row(1, "toolCall", [
            "toolCallId": .string("c"), "toolName": .string("Bash"), "status": .string("pendingApproval"),
            "inputText": .string("{}"), "input": .object(["command": .string("swift test"), "timeout": .number(60)]),
        ])
        guard case .toolCall(let call) = tool.content else { Issue.record("outil attendu"); return }
        #expect(call.summary == "swift test")
        #expect(call.status.label == "En attente d'approbation")
        let refused = try CommandAck(json: .object([
            "commandId": .string("c"), "status": .string("failed"), "reasonCode": .string("provider.notInRegistry"),
            "revisionAtDecision": .number(3),
        ]))
        #expect(ChatLabels.refusal(refused) == "Modèle indisponible sur l'hôte : choisis-en un autre.")
        let other = try CommandAck(json: .object([
            "commandId": .string("c"), "status": .string("rejected"), "reasonCode": .string("proto.sessionNotFound"),
            "message": .string("session absente"), "revisionAtDecision": .number(3),
        ]))
        #expect(ChatLabels.refusal(other) == "Commande refusée par l'hôte (session absente).")
        #expect(ChatLabels.sendLabel(routing: "enqueue") == "Mettre en file")
        #expect(ChatLabels.sendLabel(routing: "guide") == "Guider l'agent")
    }

    @Test func piedCliquableSiDesFichiersOntChange() throws {
        let rows = try [
            row(1, "turnHeader", ["state": .string("completedSuccess"), "entityId": .string("turn:a"),
                                  "fileChanges": .object(["files": .number(2), "additions": .number(3), "deletions": .number(1)])]),
            row(2, "userInput", ["text": .string("modifie")]),
            row(3, "turnHeader", turn: "t2", ["state": .string("completedSuccess"), "entityId": .string("turn:b")]),
            row(4, "userInput", turn: "t2", ["text": .string("rien")]),
            row(5, "turnHeader", turn: "t3", ["state": .string("completedSuccess"),
                                              "fileChanges": .object(["files": .number(1), "additions": .number(1), "deletions": .number(0)])]),
            row(6, "userInput", turn: "t3", ["text": .string("sans entityId")]),
        ]
        let entries = ChatTimeline.entries(from: rows)
        #expect(entries.map(\.id) == [2, 1, 4, 3, 6, 5])
        #expect(entries[1].fileChangesTarget == RowTarget(rowId: 1, entityId: "turn:a"))
        #expect(entries[3].fileChangesTarget == nil)                 // aucun fichier modifié
        #expect(entries[5].fileChangesTarget == nil)                 // en-tête impossible à viser
        #expect(entries[0].fileChangesTarget == nil)                 // un élément n'est pas un pied
    }

    @Test func texteACopierDesMessages() throws {
        let rows = try [
            row(1, "userInput", ["text": .string("Lance **les tests**")]),
            row(2, "assistantText", ["text": .string("```bash\nswift test\n```"), "state": .string("complete")]),
            row(3, "userInput", ["text": .string("  \n "), "attachments": .array([.object([
                "ref": .string("zcode-artifact://a"), "fileName": .string("a.png"), "mime": .string("image/png"),
                "bytes": .number(3),
            ])])]),
            row(4, "reasoning", ["text": .string("je réfléchis"), "state": .string("complete")]),
        ]
        let items = ChatTimeline.entries(from: rows).compactMap { entry -> ChatItem? in
            if case .item(let item) = entry.content { return item }
            return nil
        }
        #expect(items.map(\.copyableText) == ["Lance **les tests**", "```bash\nswift test\n```", nil, nil])
    }

    @Test func reflexionEnMarkdownUneFoisTerminee() throws {
        let rows = try ["streaming", "complete", "interrupted", "failed"].enumerated().map { index, state in
            try row(index + 1, "reasoning", ["text": .string("**Plan** : lire `a.swift`"), "state": .string(state)])
        }
        let reasonings = ChatTimeline.entries(from: rows).compactMap { entry -> Reasoning? in
            if case .item(.reasoning(_, let reasoning)) = entry.content { return reasoning }
            return nil
        }
        // Texte brut pendant le streaming (comme les réponses) ; Markdown dès que la ligne ne bouge plus.
        #expect(reasonings.map(\.showsMarkdown) == [false, true, true, true])
    }

    @Test func heureSurQuestionEtDerniereReponse() throws {
        func at(_ value: Double) -> [String: JSONValue] { ["createdAt": .number(value)] }
        let rows = try [
            row(1, "turnHeader", ["state": .string("completedSuccess")].merging(at(1000)) { $1 }),
            row(2, "userInput", ["text": .string("q1")].merging(at(1000)) { $1 }),
            row(3, "assistantText", ["text": .string("intermédiaire"), "state": .string("complete")].merging(at(2000)) { $1 }),
            row(4, "toolCall", ["toolCallId": .string("c"), "toolName": .string("Bash"), "status": .string("success"),
                                "inputText": .string("{}")].merging(at(2500)) { $1 }),
            row(5, "reasoning", ["text": .string("hmm"), "state": .string("complete")].merging(at(2600)) { $1 }),
            row(6, "assistantText", ["text": .string("finale"), "state": .string("complete")].merging(at(3000)) { $1 }),
        ]
        let times = Dictionary(uniqueKeysWithValues: ChatTimeline.entries(from: rows).map { ($0.id, $0.messageTime) })
        #expect(times[2] == 1000)                                   // question
        #expect(times[3] == .some(nil))                             // réponse intermédiaire : pas d'heure
        #expect(times[4] == .some(nil))                             // carte : pas d'heure
        #expect(times[5] == .some(nil))                             // réflexion : pas d'heure
        #expect(times[6] == 3000)                                   // dernière réponse du tour
        #expect(times[1] == .some(nil))                             // pied du tour : pas d'heure
    }

    @Test func tourEnCoursEtiquetteLaPlusRecente() throws {
        let answer: [String: JSONValue] = ["text": .string("a"), "state": .string("streaming"), "createdAt": .number(5)]
        let before = try [row(1, "userInput", ["text": .string("q"), "createdAt": .number(1)]), row(2, "assistantText", answer)]
        #expect(ChatTimeline.entries(from: before).last?.messageTime == 5)
        let after = before + [try row(3, "assistantText", ["text": .string("b"), "state": .string("streaming"), "createdAt": .number(9)])]
        let entries = ChatTimeline.entries(from: after)
        #expect(entries.first { $0.id == 2 }?.messageTime == nil)   // l'étiquette passe à la nouvelle réponse
        #expect(entries.first { $0.id == 3 }?.messageTime == 9)
    }

    @Test func turnIdQuiReparaitEtLignesSansTour() throws {
        let rows = try [
            row(1, "assistantText", turn: "t1", ["text": .string("a"), "state": .string("complete"), "createdAt": .number(1)]),
            row(2, "assistantText", turn: "t2", ["text": .string("b"), "state": .string("complete"), "createdAt": .number(2)]),
            row(3, "assistantText", turn: "t1", ["text": .string("c"), "state": .string("complete"), "createdAt": .number(3)]),
            row(4, "assistantText", turn: nil, ["text": .string("d"), "state": .string("complete"), "createdAt": .number(4)]),
            row(5, "assistantText", turn: nil, ["text": .string("e"), "state": .string("complete"), "createdAt": .number(5)]),
            row(6, "userInput", turn: "t3", ["text": .string("sans heure")]),
        ]
        let times = Dictionary(uniqueKeysWithValues: ChatTimeline.entries(from: rows).map { ($0.id, $0.messageTime) })
        #expect(times[1] == .some(nil))                             // t1 : seule la dernière (3) porte l'heure
        #expect(times[2] == 2)
        #expect(times[3] == 3)
        #expect(times[4] == 4)                                      // sans turnId : chaque ligne est son tour
        #expect(times[5] == 5)
        #expect(times[6] == .some(nil))                             // pas de createdAt : pas d'étiquette
    }

    @Test func heuresDeLaConversationReelle() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text-long/003-event-zcode-agent.onDynamicConversationFrame.json")
        let snapshot = try ConversationSnapshot(json: #require(wire["frame"]?["payload"]?["snapshot"]))
        let timed = ChatTimeline.entries(from: snapshot.rows).compactMap { entry in entry.messageTime.map { (entry.id, $0) } }
        #expect(timed.map(\.0) == [2, 4, 6, 10])                    // deux questions, deux réponses finales
        #expect(timed.map(\.1) == [1_791_885_161_427, 1_791_885_161_438, 1_791_886_885_514, 1_791_886_892_334])
    }
}
