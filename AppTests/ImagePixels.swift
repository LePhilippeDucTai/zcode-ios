import UIKit

/// Lecture du canal alpha d'une image (tests du rendu des formules), en RGBA 8 bits.
enum ImagePixels {
    static func alphas(_ image: UIImage) -> (width: Int, height: Int, values: [UInt8]) {
        guard let cgImage = image.cgImage else { return (0, 0, []) }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, stride(from: 3, to: data.count, by: 4).map { data[$0] })
    }

    /// Encre la plus opaque (0 : image vide).
    static func maxAlpha(_ image: UIImage) -> UInt8 {
        alphas(image).values.max() ?? 0
    }

    /// Alpha d'un coin, hors de la marge de 2 pt autour de la formule : 0 si le fond est transparent.
    static func cornerAlpha(_ image: UIImage) -> UInt8 {
        alphas(image).values.first ?? 255
    }

    /// Encre la plus opaque à droite de `fraction` de la largeur (formule large peinte jusqu'au bout ?).
    static func maxAlpha(rightOf fraction: CGFloat, of image: UIImage) -> UInt8 {
        let pixels = alphas(image)
        let start = Int(CGFloat(pixels.width) * fraction)
        var best: UInt8 = 0
        for row in 0..<pixels.height {
            for column in start..<pixels.width { best = max(best, pixels.values[row * pixels.width + column]) }
        }
        return best
    }
}
