import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Fichier prêt à téléverser.
struct PreparedAttachment: Sendable {
    let data: Data
    let fileName: String
    let mime: String
    /// Vignette JPEG de 240 px (images seulement).
    let thumbnail: Data?
}

/// Préparation des pièces jointes sur l'iPhone : une image est ramenée à 2000 px au plus (le modèle ne voit pas
/// au-delà) et réencodée — JPEG 0,85, PNG gardé en PNG —, ce qui retire aussi les métadonnées (lieu de la photo).
enum AttachmentImages {
    static let maxDimension = 2000
    static let thumbnailDimension = 240

    /// `nil` si `data` n'est pas une image lisible.
    static func prepare(_ data: Data, fileName: String) -> PreparedAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = downscaled(source, to: maxDimension) else { return nil }
        let keepsPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        let type: UTType = keepsPNG ? .png : .jpeg
        guard let encoded = encode(image, as: type) else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        return PreparedAttachment(data: encoded, fileName: base + (keepsPNG ? ".png" : ".jpg"),
                                  mime: keepsPNG ? "image/png" : "image/jpeg",
                                  thumbnail: downscaled(source, to: thumbnailDimension).flatMap { encode($0, as: .jpeg) })
    }

    /// Document (ou image illisible) envoyé tel quel ; type déduit de l'extension.
    static func prepareFile(data: Data, fileName: String) -> PreparedAttachment {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension)
        if let type, type.conforms(to: .image), let image = prepare(data, fileName: fileName) { return image }
        return PreparedAttachment(data: data, fileName: fileName,
                                  mime: type?.preferredMIMEType ?? "application/octet-stream", thumbnail: nil)
    }

    // Variantes asynchrones : le décodage / réencodage ImageIO et la lecture du fichier se font hors du fil principal
    // (une photo de 12 Mpx coûte 100 à 300 ms ; huit photos gèleraient l'interface).

    /// `prepare` hors du fil principal.
    @concurrent static func prepareOffMain(_ data: Data, fileName: String) async -> PreparedAttachment? {
        prepare(data, fileName: fileName)
    }

    /// Lit un fichier choisi dans Fichiers (accès « security-scoped ») puis le prépare, hors du fil principal.
    /// `nil` si le fichier est illisible.
    @concurrent static func prepareFile(at url: URL) async -> PreparedAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return prepareFile(data: data, fileName: url.lastPathComponent)
    }

    /// Image de l'appareil photo ou du presse-papiers : encodée puis préparée hors du fil principal.
    @concurrent static func prepare(image: UIImage, fileName: String, png: Bool) async -> PreparedAttachment? {
        guard let data = png ? image.pngData() : image.jpegData(compressionQuality: 0.9) else { return nil }
        return prepare(data, fileName: fileName)
    }

    /// Nom unique pour une image sans nom (photothèque, appareil photo, presse-papiers) : `Image 143502-1.jpg`.
    static func generatedName(_ label: String, index: Int, ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return "\(label) \(formatter.string(from: date))-\(index + 1).\(ext)"
    }

    /// Image orientée (EXIF appliqué), côté le plus long ≤ `dimension` ; jamais agrandie.
    private static func downscaled(_ source: CGImageSource, to dimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        // La qualité n'a de sens que pour le JPEG (le PNG l'ignore en écrivant un avertissement).
        let options = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
