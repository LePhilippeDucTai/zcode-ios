import Foundation
import ZCodeV4

/// Une image de la visionneuse plein écran.
public struct GalleryImage: Identifiable, Equatable, Sendable {
    /// Unique dans la galerie, même si la même image est jointe deux fois.
    public let id: String
    public let fileName: String
    /// Image à lire sur l'hôte (`ConversationModel.attachmentData(for:)`) ; `nil` tant qu'une pièce du composeur n'est
    /// pas téléversée.
    public let ref: AttachmentRef?
    /// Vignette locale (composeur), montrée en attendant l'image lue, ou à sa place si la lecture échoue.
    public let thumbnail: Data?
}

/// Images d'un message envoyé (ou du composeur) à faire défiler en plein écran ; les documents en sont exclus.
public struct ImageGallery: Identifiable, Equatable, Sendable {
    public let images: [GalleryImage]
    public let startIndex: Int

    public var id: String { images[startIndex].id }

    /// Glissé vers le bas (pt) au-delà duquel la visionneuse se ferme.
    public static let dismissDistance: Double = 120

    /// Le glissé ferme la visionneuse : assez long, vers le bas, plus vertical qu'horizontal.
    public static func dismisses(horizontal: Double, vertical: Double) -> Bool {
        vertical > dismissDistance && abs(horizontal) < vertical
    }

    /// Vignette `index` touchée dans un message envoyé ; `nil` pour un document.
    public static func sent(_ attachments: [AttachmentRef], tapped index: Int) -> ImageGallery? {
        guard attachments.indices.contains(index), attachments[index].isImage else { return nil }
        let images = attachments.enumerated().filter { $0.element.isImage }
        guard let start = images.firstIndex(where: { $0.offset == index }) else { return nil }
        return ImageGallery(images: images.map { offset, ref in
            GalleryImage(id: "\(offset):\(ref.readableRef)", fileName: ref.fileName, ref: ref, thumbnail: nil)
        }, startIndex: start)
    }

    /// Vignette touchée dans le composeur : l'image lue sur l'hôte une fois téléversée (les données locales ne sont pas
    /// gardées après l'envoi), sinon la vignette seule ; `nil` pour un document.
    public static func composer(_ attachments: [ComposerAttachment], tapped id: UUID) -> ImageGallery? {
        let images = attachments.filter { $0.mime.lowercased().hasPrefix("image/") }
        guard let start = images.firstIndex(where: { $0.id == id }) else { return nil }
        return ImageGallery(images: images.map {
            GalleryImage(id: $0.id.uuidString, fileName: $0.fileName, ref: $0.reference, thumbnail: $0.thumbnail)
        }, startIndex: start)
    }
}
