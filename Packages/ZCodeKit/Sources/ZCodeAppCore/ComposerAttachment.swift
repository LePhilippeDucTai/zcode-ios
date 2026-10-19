import Foundation
import ZCodeV4

/// Pièce jointe du prochain message, téléversée dès son choix.
public struct ComposerAttachment: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case uploading
        case ready(AttachmentRef)
        case failed(String)
    }

    public let id: UUID
    public let fileName: String
    public let mime: String
    public let bytes: Int
    /// Vignette fournie par l'app (image réduite) ; `nil` pour un document ou une pièce rendue après un abandon.
    public let thumbnail: Data?
    public internal(set) var state: State

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var reference: AttachmentRef? {
        if case .ready(let ref) = state { return ref }
        return nil
    }
}
