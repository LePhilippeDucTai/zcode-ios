import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct RowsTests {
    @Test func lignesDuSnapshotReel() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text/004-event-zcode-agent.onDynamicConversationFrame.json")
        let window = try #require(wire["frame"]?["payload"]?["snapshot"]?["rows"]?["window"]?.arrayValue)
        let rows = window.compactMap(ConversationRow.init(json:))
        #expect(rows.map(\.kind) == [.turnHeader, .userInput, .reasoning, .assistantText])
        #expect(rows.map(\.rowId) == [1, 2, 3, 4])
        guard case .turnHeader(let header) = rows[0].content else { Issue.record("en-tête attendu"); return }
        #expect(header.state == .completedSuccess)
        guard case .userInput(let input) = rows[1].content else { Issue.record("saisie attendue"); return }
        #expect(input.text == "réponds moi PONG")
        #expect(input.inputOrigin == "mobile")
        guard case .assistantText(let answer) = rows[3].content else { Issue.record("réponse attendue"); return }
        #expect(answer.text == "PONG")
        #expect(answer.state == .complete)
        #expect(rows[3].turnId == "msg_mv6i5rdc_be61022c-a9d5-4a93-bc3c-7cc5ee00727d")
        #expect(rows[3].entityId == "msg_mv6i5rdq_805f0286-2479-4853-8b83-df66bd8b2f68")
    }

    @Test func appelDOutilReel() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text/008-event-zcode-agent.onDynamicConversationFrame.json")
        let delta = try #require(wire["frame"]?["payload"]?["deltas"]?.arrayValue?.first)
        let rowJSON = try #require(delta["row"])
        let row = try #require(ConversationRow(json: rowJSON))
        guard case .toolCall(let call) = row.content else { Issue.record("appel d'outil attendu"); return }
        #expect(call.toolName == "Bash")
        #expect(call.status == .success)
        #expect(call.input?["command"] == .string("ls -la /Users/me/claude"))
        #expect(call.output?.text.hasPrefix("total ") == true)
    }

    @Test func typeInconnuConserve() throws {
        let json: JSONValue = .object([
            "rowId": .number(9), "kind": .string("hologram"), "turnId": .string("t"),
            "createdAt": .number(1), "createdAtSeq": .number(1), "payload": .object(["x": .number(1)]),
        ])
        let row = try #require(ConversationRow(json: json))
        #expect(row.kind.rawValue == "hologram")
        #expect(row.content == .unsupported)
        #expect(row.raw["payload"] == .object(["x": .number(1)]))
        #expect(row.json == json)
    }

    @Test func ligneConnueMalFormeeNonPriseEnCharge() throws {
        let row = try #require(ConversationRow(json: .object([
            "rowId": .number(3), "kind": .string("assistantText"), "state": .string("complete"),
        ])))
        #expect(row.kind == .assistantText)
        #expect(row.content == .unsupported)
    }

    @Test func valeursEtChampsInconnusToleres() throws {
        let row = try #require(ConversationRow(json: .object([
            "rowId": .number(8), "kind": .string("toolCall"), "toolCallId": .string("c1"), "toolName": .string("Teleport"),
            "status": .string("teleporting"), "inputText": .string("{}"), "champFutur": .array([]),
        ])))
        guard case .toolCall(let call) = row.content else { Issue.record("appel d'outil attendu"); return }
        #expect(call.status.rawValue == "teleporting")
        #expect(call.output == nil)
    }

    @Test func ligneSansRowIdRefusee() {
        #expect(ConversationRow(json: .object(["kind": .string("userInput"), "text": .string("x")])) == nil)
        #expect(ConversationRow(json: .object(["rowId": .number(1.5), "kind": .string("userInput")])) == nil)
        #expect(ConversationRow(json: .string("x")) == nil)
    }

    @Test func ajoutDeTexteEnStreaming() throws {
        func row(_ fields: [String: JSONValue]) throws -> ConversationRow {
            try #require(ConversationRow(json: .object(fields.merging(["rowId": .number(1)]) { $1 })))
        }
        let text = try row(["kind": .string("assistantText"), "text": .string("Bon"), "state": .string("streaming")])
        guard case .assistantText(let answer) = text.appending("jour", at: .text).content else { Issue.record("texte"); return }
        #expect(answer.text == "Bonjour")

        let reasoning = try row(["kind": .string("reasoning"), "text": .string(""), "state": .string("streaming")])
        guard case .reasoning(let thought) = reasoning.appending("Je réfléchis", at: .text).content else { Issue.record("raisonnement"); return }
        #expect(thought.text == "Je réfléchis")

        let tool = try row(["kind": .string("toolCall"), "toolCallId": .string("c"), "toolName": .string("Bash"),
                            "status": .string("inputStreaming"), "inputText": .string("{\"comm")])
        guard case .toolCall(let streamed) = tool.appending("and\":1}", at: .inputText).content else { Issue.record("entrée"); return }
        #expect(streamed.inputText == "{\"command\":1}")
        #expect(tool.appending("x", at: .text) == tool)            // chemin sans objet pour ce type
        #expect(tool.appending("x", at: .outputText) == tool)      // pas encore de sortie

        let withOutput = try row(["kind": .string("toolCall"), "toolCallId": .string("c"), "toolName": .string("Bash"),
                                  "status": .string("running"), "inputText": .string(""),
                                  "output": .object(["text": .string("ligne 1\n")])])
        guard case .toolCall(let running) = withOutput.appending("ligne 2\n", at: .outputText).content else { Issue.record("sortie"); return }
        #expect(running.output?.text == "ligne 1\nligne 2\n")

        let subagent = try row(["kind": .string("subagent"), "subagentType": .string("explore"),
                                "status": .string("running"), "summaryText": .string("A")])
        guard case .subagent(let child) = subagent.appending("B", at: .summaryText).content else { Issue.record("sous-agent"); return }
        #expect(child.summaryText == "AB")
        #expect(text.appending("x", at: StreamablePath(rawValue: "future.path")) == text)
    }

    static func row(_ object: [String: JSONValue]) throws -> ConversationRow {
        try #require(ConversationRow(json: .object(object)))
    }

    @Test func deltaIdentiqueAUnRedecodage() throws {
        let rows = try [
            Self.row(["rowId": .number(1), "kind": .string("assistantText"), "text": .string("Bon"), "state": .string("streaming")]),
            Self.row(["rowId": .number(2), "kind": .string("reasoning"), "text": .string(""), "state": .string("streaming")]),
            Self.row([
                "rowId": .number(3), "kind": .string("toolCall"), "toolCallId": .string("t"), "toolName": .string("Bash"),
                "status": .string("running"), "inputText": .string("{\"command\":"),
                "output": .object(["text": .string("ligne 1\n")]),
            ]),
            Self.row([
                "rowId": .number(4), "kind": .string("subagent"), "subagentType": .string("explore"),
                "status": .string("running"), "summaryText": .string("Lecture"),
            ]),
        ]
        let cases: [(ConversationRow, StreamablePath)] = [
            (rows[0], .text), (rows[1], .text), (rows[2], .inputText), (rows[2], .outputText), (rows[3], .summaryText),
            (rows[0], .outputText),                                   // chemin sans objet : ligne inchangée
        ]
        for (row, path) in cases {
            let fast = row.appending("jour ✓", at: path)
            #expect(fast == ConversationRow(json: fast.json), "contenu typé cohérent avec le JSON pour \(path)")
        }
        let expected = try V4JSON.decode(AssistantText.self, from: .object(["text": .string("Bonjour"), "state": .string("streaming")]))
        #expect(rows[0].appending("jour", at: .text).content == .assistantText(expected))
        #expect(rows[0].appending("x", at: .outputText) == rows[0])
    }

    @Test func streamingLongBorne() throws {
        var snapshot = try ConversationSnapshot(json: #require(snapshotJSON(record("send-text-long", "003"))))
        snapshot.apply(.rowAppended(try Self.row([
            "rowId": .number(9_000), "kind": .string("assistantText"), "text": .string(""), "state": .string("streaming"),
        ])))
        let chunk = String(repeating: "abcdefghij", count: 5)          // 50 caractères
        let start = ContinuousClock.now
        for _ in 0..<10_000 {
            snapshot.apply(.rowDelta(rowId: 9_000, path: .text, append: chunk))
        }
        let elapsed = ContinuousClock.now - start
        guard case .assistantText(let text)? = snapshot.row(id: 9_000)?.content else { Issue.record("ligne perdue"); return }
        #expect(text.text.count == 500_000)
        #expect(elapsed < .seconds(2), "10 000 deltas en \(elapsed)")
    }
}
