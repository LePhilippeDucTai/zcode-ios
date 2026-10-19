import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZCode

final class AttachmentImagesTests: XCTestCase {
    /// Image unie `width × height` encodée dans `type`.
    private func image(_ width: Int, _ height: Int, type: UTType) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.86, green: 0.08, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
    }

    func testGrandePhotoReduiteEnJPEG() throws {
        let prepared = try XCTUnwrap(AttachmentImages.prepare(image(4000, 3000, type: .heic), fileName: "IMG_0001.HEIC"))
        XCTAssertEqual(prepared.mime, "image/jpeg")
        XCTAssertEqual(prepared.fileName, "IMG_0001.jpg")
        let (width, height) = pixelSize(prepared.data)
        XCTAssertEqual(max(width, height), 2000)
        XCTAssertEqual(width * 3, height * 4)                                      // proportions gardées
        XCTAssertNotNil(prepared.thumbnail)
    }

    func testPNGResteEnPNG() throws {
        let prepared = try XCTUnwrap(AttachmentImages.prepare(image(800, 600, type: .png), fileName: "capture.png"))
        XCTAssertEqual(prepared.mime, "image/png")
        XCTAssertEqual(prepared.fileName, "capture.png")
        XCTAssertEqual(pixelSize(prepared.data).0, 800)                            // pas agrandie
    }

    func testDonneesIllisibles() {
        XCTAssertNil(AttachmentImages.prepare(Data("pas une image".utf8), fileName: "x.jpg"))
    }

    func testDocumentTelQuel() {
        let prepared = AttachmentImages.prepareFile(data: Data("# Titre".utf8), fileName: "notes.md")
        XCTAssertEqual(prepared.mime, "text/markdown")
        XCTAssertNil(prepared.thumbnail)
        XCTAssertEqual(AttachmentImages.prepareFile(data: Data([0]), fileName: "inconnu.zzz").mime, "application/octet-stream")
    }

    func testPreparationHorsFilPrincipal() async throws {
        let result = await AttachmentImages.prepareOffMain(image(1000, 500, type: .jpeg), fileName: "a.jpg")
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(prepared.mime, "image/jpeg")
        let unreadable = await AttachmentImages.prepareOffMain(Data("pas une image".utf8), fileName: "x.jpg")
        XCTAssertNil(unreadable)
    }

    func testFichierLuHorsFilPrincipal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        try Data("# Titre".utf8).write(to: url)
        let result = await AttachmentImages.prepareFile(at: url)
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(prepared.fileName, "notes.md")
        XCTAssertEqual(prepared.mime, "text/markdown")
        let missing = await AttachmentImages.prepareFile(at: directory.appendingPathComponent("absent.txt"))
        XCTAssertNil(missing)
    }

    func testNomsGeneresUniques() {
        let date = Date(timeIntervalSince1970: 0)
        let first = AttachmentImages.generatedName("Image", index: 0, ext: "jpg", date: date)
        let second = AttachmentImages.generatedName("Image", index: 1, ext: "jpg", date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("Image ") && first.hasSuffix("-1.jpg"))
        XCTAssertTrue(second.hasSuffix("-2.jpg"))
    }

    func testPNGEncodeSansQualite() throws {
        // La qualité JPEG n'est plus passée au PNG (ImageIO écrivait « unrecognised property key »).
        let prepared = try XCTUnwrap(AttachmentImages.prepare(image(100, 100, type: .png), fileName: "p.png"))
        XCTAssertEqual(prepared.mime, "image/png")
    }
}
