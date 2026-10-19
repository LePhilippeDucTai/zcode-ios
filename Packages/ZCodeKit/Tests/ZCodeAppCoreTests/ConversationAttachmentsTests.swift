import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationAttachmentsTests {
    /// Hôte qui accepte tout téléversement ; `failChunks` fait échouer les morceaux.
    func uploadServer(failChunks: Bool = false) async throws -> FakeZCodeServer {
        let server = try await conversationServer()
        await acceptUploads(on: server, failChunks: failChunks)
        return server
    }

    func readyModel(_ server: FakeZCodeServer) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func lastEnvelope(_ server: FakeZCodeServer) async -> JSONValue? {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").last?["envelope"]
    }

    @Test func televersementDesLeChoixPuisEnvoi() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        #expect(model.attach(data: Data([1, 2, 3]), fileName: "a.png", mime: "image/png"))
        #expect(model.attachments.count == 1)
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("regarde") == .sent(delivery: "startNow"))
        let envelope = try #require(await lastEnvelope(server))
        let sent = try #require(envelope["payload"]?["attachments"]?.arrayValue)
        #expect(sent.count == 1 && sent.first?["fileName"] == .string("a.png") && sent.first?["bytes"] == .number(3))
        #expect(model.attachments.isEmpty)                                         // envoyées : retirées du composeur
    }

    @Test func galerieDuComposeur() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        model.attach(data: Data([1, 2]), fileName: "a.png", mime: "image/png", thumbnail: Data([9]))
        model.attach(data: Data([3]), fileName: "b.pdf", mime: "application/pdf")
        _ = try await eventually { model.attachments.allSatisfy(\.isReady) ? true : nil }
        let image = try #require(model.attachments.first)
        let gallery = try #require(ImageGallery.composer(model.attachments, tapped: image.id))
        #expect(gallery.images.count == 1)                                                 // pas le PDF
        #expect(gallery.images.first?.thumbnail == Data([9]))
        guard case .ready(let ref) = image.state else { Issue.record("pièce prête attendue"); return }
        #expect(gallery.images.first?.ref == ref)                                          // lue sur l'hôte
        #expect(ImageGallery.composer(model.attachments, tapped: model.attachments[1].id) == nil)
    }

    @Test func galerieDuComposeurPendantLeTeleversement() async throws {
        let server = try await uploadServer()
        await server.on("zcode-agent.attachmentCommitV4") { _ in
            Thread.sleep(forTimeInterval: 0.5)                                             // commit lent
            return .object(["ref": .string("zcode-artifact://lent")])
        }
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.jpg", mime: "image/jpeg", thumbnail: Data([7]))
        let gallery = try #require(ImageGallery.composer(model.attachments, tapped: model.attachments[0].id))
        #expect(gallery.images.first?.ref == nil)                                          // vignette seule
        #expect(gallery.images.first?.thumbnail == Data([7]))
        _ = try await eventually { model.canSendAttachments ? true : nil }
    }

    @Test func envoiPiecesJointesSansTexte() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("   ") == .sent(delivery: "startNow"))
        #expect(await lastEnvelope(server)?["payload"]?["text"] == .string(ConversationModel.attachmentOnlyText))
        #expect(await model.send("") == .failed)                                   // ni texte ni pièce jointe
    }

    @Test func envoiBloqueTantQueTeleversementEnCours() async throws {
        let server = try await uploadServer()
        await server.on("zcode-agent.attachmentCommitV4") { _ in
            Thread.sleep(forTimeInterval: 0.5)                                     // commit lent
            return .object(["ref": .string("zcode-artifact://lent")])
        }
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        #expect(!model.canSendAttachments)
        #expect(await model.send("vite") == .failed)
        #expect(model.commandError == "Pièce jointe en cours d'envoi : attends la fin du téléversement.")
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)
        _ = try await eventually { model.canSendAttachments ? true : nil }
    }

    @Test func echecPuisNouvelEssai() async throws {
        let server = try await uploadServer(failChunks: true)
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        let failed = try await eventually { () -> String? in
            if case .failed(let message) = model.attachments.first?.state { return message }
            return nil
        }
        #expect(failed.hasPrefix("Envoi de la pièce jointe impossible"))
        #expect(await server.calls(to: "zcode-agent.attachmentAbortV4").count == 1)
        #expect(await model.send("x") == .failed)                                 // une pièce en échec bloque l'envoi
        await server.on("zcode-agent.attachmentChunkV4") { argument in
            .object(["uploadId": argument["uploadId"] ?? .null, "nextChunkIndex": .number(1)])
        }
        model.retryAttachment(try #require(model.attachments.first?.id))
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
    }

    @Test func refusTropGrosEtTropNombreux() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        #expect(!model.attach(data: Data(count: ConversationModel.maxAttachmentBytes + 1), fileName: "gros.mov", mime: "video/quicktime"))
        #expect(model.commandError == "Fichier trop gros : 20 Mo au plus par pièce jointe.")
        for index in 0..<ConversationModel.maxAttachments {
            #expect(model.attach(data: Data([UInt8(index)]), fileName: "\(index).png", mime: "image/png"))
        }
        #expect(!model.attach(data: Data([9]), fileName: "9.png", mime: "image/png"))
        #expect(model.commandError == "8 pièces jointes au plus par message.")
        #expect(model.attachments.count == ConversationModel.maxAttachments)
        _ = try await eventually {
            await server.calls(to: "zcode-agent.attachmentBeginV4").count == ConversationModel.maxAttachments ? true : nil
        }
        try await Task.sleep(for: .milliseconds(100))                              // aucun téléversement de trop
        #expect(await server.calls(to: "zcode-agent.attachmentBeginV4").count == ConversationModel.maxAttachments)
    }

    @Test func retraitPendantLeTeleversement() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        model.removeAttachment(try #require(model.attachments.first?.id))
        #expect(model.attachments.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.attachments.isEmpty)                                         // un téléversement fini ne la remet pas
    }

    @Test func refusGardeLesPiecesJointes() async throws {
        let server = try await uploadServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("guard.busy"), "revisionAtDecision": .number(9)])
        }
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("x") == .failed)
        #expect(model.attachments.count == 1)
    }

    @Test func goalAvecPieceJointeRefuse() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("/goal tests verts") == .failed)
        #expect(model.commandError == "Un Goal ne prend pas de pièce jointe : retire-la ou envoie un message.")
        #expect(await server.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)
    }

    @Test func lectureDUneImageEnCache() async throws {
        let server = try await uploadServer()
        await server.on("zcode-agent.attachmentReadV4") { _ in
            .object(["dataBase64": .string(Data([9, 9]).base64EncodedString()), "mediaType": .string("image/png"),
                     "totalBytes": .number(2), "nextOffset": .null])
        }
        let model = try await readyModel(server)
        let image = AttachmentRef(ref: "zcode-artifact://i", fileName: "i.png", mime: "image/png", bytes: 2)
        #expect(await model.attachmentData(for: image) == Data([9, 9]))
        #expect(await model.attachmentData(for: image) == Data([9, 9]))
        #expect(await server.calls(to: "zcode-agent.attachmentReadV4").count == 1)        // cache
        let document = AttachmentRef(ref: "zcode-artifact://d", fileName: "d.txt", mime: "text/plain", bytes: 2)
        #expect(await model.attachmentData(for: document) == nil)                         // pas d'aperçu
        #expect(await server.calls(to: "zcode-agent.attachmentReadV4").count == 1)
    }

    @Test func cacheDesImagesBorneEnOctets() async throws {
        let server = try await uploadServer()
        let big = Data(count: 7 * 1024 * 1024)                                     // 4 x 7 Mio > 24 Mio (lecture : 8 Mio au plus)
        await server.on("zcode-agent.attachmentReadV4") { _ in
            .object(["dataBase64": .string(big.base64EncodedString()), "mediaType": .string("image/png"),
                     "totalBytes": .number(Double(big.count)), "nextOffset": .null])
        }
        let model = try await readyModel(server)
        func image(_ name: String) -> AttachmentRef {
            AttachmentRef(ref: "zcode-artifact://\(name)", fileName: "\(name).png", mime: "image/png", bytes: big.count)
        }
        for name in ["a", "b", "c", "d"] { #expect(await model.attachmentData(for: image(name))?.count == big.count) }
        #expect(await server.calls(to: "zcode-agent.attachmentReadV4").count == 4)
        _ = await model.attachmentData(for: image("d"))                            // la plus récente reste en cache
        #expect(await server.calls(to: "zcode-agent.attachmentReadV4").count == 4)
        _ = await model.attachmentData(for: image("a"))                            // la plus ancienne a été oubliée
        #expect(await server.calls(to: "zcode-agent.attachmentReadV4").count == 5)
    }

    @Test func nomEtTypeAssainis() async throws {
        let server = try await uploadServer()
        let model = try await readyModel(server)
        #expect(model.attach(data: Data([1]), fileName: "re\nçu\0.png\r", mime: "image"))
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        let begin = try #require(await server.calls(to: "zcode-agent.attachmentBeginV4").first)
        #expect(begin["fileName"] == .string("reçu.png"))
        #expect(begin["mime"] == .string("application/octet-stream"))
        #expect(model.attachments.first?.fileName == "reçu.png")
        #expect(model.attach(data: Data([1]), fileName: " \n ", mime: "image/svg+xml"))
        #expect(model.attachments.last?.fileName == "Pièce jointe")
        #expect(model.attachments.last?.mime == "image/svg+xml")
        let long = String(repeating: "é", count: 300) + ".png"
        #expect(model.attach(data: Data([1]), fileName: long, mime: "image/png"))
        #expect(model.attachments.last?.fileName.count == 255)
    }
}

/// Gestionnaires de téléversement (début, morceaux, validation, abandon) d'un hôte qui accepte tout.
func acceptUploads(on server: FakeZCodeServer, failChunks: Bool = false) async {
    await server.on("zcode-agent.attachmentBeginV4") { argument in
        .object(["uploadId": argument["uploadId"] ?? .null, "state": .string("staging"), "nextChunkIndex": .number(0)])
    }
    await server.on("zcode-agent.attachmentChunkV4") { argument in
        if failChunks { throw FakeRemoteError("fault.attachment.stagingCapacityExceeded") }
        return .object(["uploadId": argument["uploadId"] ?? .null,
                        "nextChunkIndex": .number(Double((V4JSON.integer(argument["chunkIndex"]) ?? 0) + 1))])
    }
    await server.on("zcode-agent.attachmentCommitV4") { argument in
        .object(["ref": .string("zcode-artifact://\(argument["uploadId"]?.stringValue ?? "x")")])
    }
    await server.on("zcode-agent.attachmentAbortV4") { _ in .object([:]) }
}
