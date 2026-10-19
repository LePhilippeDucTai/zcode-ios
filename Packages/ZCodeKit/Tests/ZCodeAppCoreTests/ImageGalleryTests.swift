import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4

struct ImageGalleryTests {
    let photo = AttachmentRef(ref: "zcode-artifact://p", fileName: "photo.jpg", mime: "image/jpeg", bytes: 10)
    let pdf = AttachmentRef(ref: "zcode-artifact://d", fileName: "notes.pdf", mime: "application/pdf", bytes: 20)
    let capture = AttachmentRef(ref: "zcode-artifact://c", fileName: "capture.png", mime: "IMAGE/PNG", bytes: 30,
                                previewRef: "zcode-artifact://c-apercu")

    @Test func galerieDUnMessageEnvoye() throws {
        let attachments = [photo, pdf, capture, photo]                                     // la photo jointe deux fois
        let gallery = try #require(ImageGallery.sent(attachments, tapped: 2))
        #expect(gallery.images.map(\.fileName) == ["photo.jpg", "capture.png", "photo.jpg"])
        #expect(gallery.startIndex == 1)
        #expect(Set(gallery.images.map(\.id)).count == 3)                                   // aucun identifiant en double
        #expect(gallery.images[1].ref == capture)
        #expect(gallery.images[1].id.hasSuffix("zcode-artifact://c-apercu"))
        #expect(try #require(ImageGallery.sent(attachments, tapped: 3)).startIndex == 2)
        #expect(ImageGallery.sent(attachments, tapped: 1) == nil)                          // document
        #expect(ImageGallery.sent(attachments, tapped: 9) == nil)
    }

    @Test func glisserVersLeBasPourFermer() {
        #expect(ImageGallery.dismisses(horizontal: 0, vertical: 130))
        #expect(!ImageGallery.dismisses(horizontal: 0, vertical: 100))                      // trop court
        #expect(!ImageGallery.dismisses(horizontal: 200, vertical: 130))                    // défilement entre images
        #expect(!ImageGallery.dismisses(horizontal: 0, vertical: -200))                     // vers le haut
    }
}
