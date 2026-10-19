import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationSlashCommandsTests {
    func readyModel(_ server: FakeZCodeServer, _ edit: @escaping (inout [String: JSONValue]) -> Void = { _ in }) async throws
        -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame { edit(&$0) })
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func envelopes(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func analyseCommeLeWeb() {
        #expect(SlashSendCommand.parse("/plan", hasAttachments: false) == .plan(task: ""))
        #expect(SlashSendCommand.parse("  /PLAN  refais\nle module ", hasAttachments: false) == .plan(task: "refais\nle module"))
        #expect(SlashSendCommand.parse("/plan x", hasAttachments: true) == .planWithAttachments)
        #expect(SlashSendCommand.parse("/compact résume bien", hasAttachments: false) == .compact)
        #expect(SlashSendCommand.parse("/compress", hasAttachments: false) == .compact)
        #expect(SlashSendCommand.parse("/compact", hasAttachments: true) == nil)    // part en texte, comme le web
        for text in ["/planifie", "/compacte", "/workflow x", "/init", "plan", "/", "/goal x"] {
            #expect(SlashSendCommand.parse(text, hasAttachments: false) == nil, "\(text)")
        }
    }

    @Test func planSansTacheBasculeSeulement() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.send("/plan") == .sent(delivery: nil))
        #expect(model.settings?.displayedMode == "plan")
        #expect(await envelopes(server).isEmpty)                                   // rien n'est envoyé
    }

    @Test func planAvecTacheEnvoieLaTacheSeuleEnModePlan() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.send("/plan refactorise le module") == .sent(delivery: "startNow"))
        let envelope = try #require(await envelopes(server).first)
        #expect(envelope["type"] == .string("sendText"))
        #expect(envelope["payload"]?["text"] == .string("refactorise le module"))
        #expect(envelope["payload"]?["planEnabled"] == .bool(true) && envelope["payload"]?["mode"] == .string("build"))
    }

    @Test func planAvecPieceJointeRefuse() async throws {
        let server = try await conversationServer()
        await acceptUploads(on: server)
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("/plan regarde") == .failed)
        #expect(model.commandError == "/plan ne prend pas de pièce jointe : retire-la ou envoie un message.")
        #expect(await envelopes(server).isEmpty)
    }

    @Test func compactEnvoieLaCommandeSansCAS() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.send("/compact garde les décisions") == .sent(delivery: nil))
        let envelope = try #require(await envelopes(server).first)
        #expect(envelope["type"] == .string("compact") && envelope["payload"] == .object([:]))
        #expect(envelope["baseRevision"] == nil)
        #expect(model.commandNotice == nil)                                        // routage startNow : rien en file
    }

    @Test func compactSansDialogueDeFile() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server) {
            $0["inputRouting"] = .object(["mode": .string("choice")])
            $0["control"] = .object(["phase": .string("running"), "canStop": .bool(true), "activeWorks": .array([])])
        }
        #expect(await model.send("/compact") == .sent(delivery: nil))              // pas de needsQueueChoice
        #expect(await envelopes(server).first?["type"] == .string("compact"))
        #expect(model.commandNotice == "Compression du contexte mise en file : elle partira après le tour en cours.")
        model.dismissCommandNotice()
        #expect(model.commandNotice == nil)
    }

    @Test func envoiEffaceLAvisDeCompression() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server) {
            $0["inputRouting"] = .object(["mode": .string("choice")])
            $0["control"] = .object(["phase": .string("running"), "canStop": .bool(true), "activeWorks": .array([])])
        }
        #expect(await model.send("/compact") == .sent(delivery: nil))
        #expect(model.commandNotice != nil)
        _ = await model.send("suite", heldQueue: .init(.keepQueueAndSend, expectedItemIds: []))             // tout envoi efface l'avis
        #expect(model.commandNotice == nil)
    }

    @Test func compactRefusTraduits() async throws {
        let server = try await conversationServer()
        let reasons = Counter()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            interactionAck(argument, "rejected", reasonCode: reasons.next() == 1 ? "compactOperationLock" : "activeTurn")
        }
        let model = try await readyModel(server)
        #expect(await model.send("/compact") == .failed)
        #expect(model.commandError == "Une compression du contexte est en cours : réessaie quand elle sera finie.")
        #expect(await model.send("/compact") == .failed)
        #expect(model.commandError == "Attends la fin du tour en cours pour compresser le contexte.")
    }

    @Test func autresCommandesPartentTellesQuelles() async throws {
        let server = try await conversationServer()
        let model = try await readyModel(server)
        #expect(await model.send("/workflow trie les imports") == .sent(delivery: "startNow"))
        #expect(await envelopes(server).first?["payload"]?["text"] == .string("/workflow trie les imports"))
    }
}
