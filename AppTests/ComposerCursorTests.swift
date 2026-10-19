import SwiftUI
import XCTest
@testable import ZCode

final class ComposerCursorTests: XCTestCase {
    func testSansSelectionLeCurseurEstEnFin() {
        let split = ComposerCursor.split("bonjour", nil)
        XCTAssertEqual(split?.before, "bonjour")
        XCTAssertEqual(split?.after, "")
    }

    func testCurseurAuMilieu() {
        let text = "bonjour"
        let selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: 3))
        let split = ComposerCursor.split(text, selection)
        XCTAssertEqual(split?.before, "bon")
        XCTAssertEqual(split?.after, "jour")
    }

    /// Régression : l'index date d'un texte plus long (brouillon raccourci depuis) ; `utf16Offset(in:)` plantait.
    func testIndexPerimeAuDelaDeLaFin() {
        let long = "/plan une tâche assez longue"
        let selection = TextSelection(insertionPoint: long.endIndex)
        let split = ComposerCursor.split("/pl", selection)
        XCTAssertEqual(split?.before, "/pl")
        XCTAssertEqual(split?.after, "")
        let empty = ComposerCursor.split("", selection)
        XCTAssertEqual(empty?.before, "")
        XCTAssertEqual(empty?.after, "")
    }

    /// Index au milieu d'une paire de substitution (emoji) : ramené sans planter.
    func testIndexAuMilieuDUnEmoji() {
        let text = "a😀b"
        let middle = text.utf16.index(text.utf16.startIndex, offsetBy: 2)
        let split = ComposerCursor.split(text, TextSelection(insertionPoint: middle))
        XCTAssertNotNil(split)
        XCTAssertEqual((split?.before ?? "") + (split?.after ?? ""), text)
    }

    func testSelectionNonVideOuvreRien() {
        let text = "bonjour"
        let range = text.startIndex..<text.index(text.startIndex, offsetBy: 3)
        XCTAssertNil(ComposerCursor.split(text, TextSelection(range: range)))
    }
}
