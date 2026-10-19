import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct AttachmentsTests {
    let image = AttachmentRef(ref: "zcode-artifact://a1", fileName: "photo.jpg", mime: "image/jpeg", bytes: 1234)

    @Test func referenceEnJSON() {
        #expect(image.json == .object(["ref": .string("zcode-artifact://a1"), "fileName": .string("photo.jpg"),
                                       "mime": .string("image/jpeg"), "bytes": .number(1234)]))
        #expect(image.isImage)
        #expect(image.readableRef == "zcode-artifact://a1")
        let preview = AttachmentRef(ref: "r", fileName: "v.mov", mime: "video/quicktime", bytes: 9, previewRef: "p")
        #expect(preview.json["previewRef"] == .string("p") && preview.readableRef == "p" && !preview.isImage)
    }

    @Test func envoiAvecPiecesJointes() {
        let builder = CommandBuilder(clientId: "client-test")
        let envelope = builder.sendText(sessionId: "s", text: "", attachments: [image])
        #expect(envelope.payload["attachments"] == .array([image.json]))
        #expect(envelope.payload["text"] == .string(""))
        #expect(builder.sendText(sessionId: "s", text: "x").payload["attachments"] == nil)
    }

    @Test func ligneUtilisateurTolerante() throws {
        let row: JSONValue = .object([
            "text": .string("regarde"),
            "attachments": .array([
                image.json,
                .object(["ref": .string("cassée")]),                              // illisible : ignorée
            ]),
        ])
        let input = try V4JSON.decode(UserInput.self, from: row)
        #expect(input.text == "regarde")
        #expect(input.attachments == [image])
        #expect(try V4JSON.decode(UserInput.self, from: .object(["text": .string("t")])).attachments.isEmpty)
    }

    @Test func ligneUtilisateurReelle() throws {
        let record = try #require(try Fixtures.records(in: "v3.15.1/attachments").first { $0.file.hasSuffix("userInput.json") })
        let row = try #require(ConversationRow(json: record.value))
        guard case .userInput(let input) = row.content else { Issue.record("pas une ligne userInput"); return }
        let attachment = try #require(input.attachments.first)
        #expect(attachment.fileName == "carre-rouge.png" && attachment.mime == "image/png" && attachment.bytes == 137)
        #expect(attachment.ref.contains("://"))
    }
}
