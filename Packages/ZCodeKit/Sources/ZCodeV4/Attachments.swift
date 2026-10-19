import Foundation
import ZCodeWire

/// Pièce jointe d'un message (`attachmentRefSchema`) : `ref` = `zcode-artifact://…` rendu par l'hôte au téléversement
/// (`attachmentCommitV4`), valable 24 h tant qu'aucun message ne la cite.
public struct AttachmentRef: Codable, Hashable, Sendable {
    public let ref: String
    public let fileName: String
    public let mime: String
    public let bytes: Int
    /// Aperçu calculé par l'hôte (vidéo) ; à lire de préférence à `ref`.
    public let previewRef: String?

    public init(ref: String, fileName: String, mime: String, bytes: Int, previewRef: String? = nil) {
        self.ref = ref
        self.fileName = fileName
        self.mime = mime
        self.bytes = bytes
        self.previewRef = previewRef
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "ref": .string(ref), "fileName": .string(fileName), "mime": .string(mime), "bytes": .number(Double(bytes)),
        ]
        if let previewRef { object["previewRef"] = .string(previewRef) }
        return .object(object)
    }

    public var isImage: Bool { mime.lowercased().hasPrefix("image/") }

    /// Référence à passer à `attachmentReadV4` (comme le web : l'aperçu s'il existe).
    public var readableRef: String { previewRef ?? ref }
}
