import SwiftUI
import XCTest
@testable import ZCode

final class FormulaStyleTests: XCTestCase {
    func testCouleurCss() {
        XCTAssertEqual(FormulaStyle.css(UIColor(red: 1, green: 0, blue: 0, alpha: 0.5)), "rgba(255,0,0,0.500)")
    }

    /// Mode sombre ou grande taille de texte : autre clé, donc nouvelle image (jamais l'image noire du mode clair).
    @MainActor
    func testCleSuitLeModeEtLaTaille() {
        let style = FormulaStyle(textStyle: .body, secondary: false)
        let light = style.key(latex: "x", display: false, dynamicTypeSize: .large, colorScheme: .light, scale: 3)
        let dark = style.key(latex: "x", display: false, dynamicTypeSize: .large, colorScheme: .dark, scale: 3)
        let large = style.key(latex: "x", display: false, dynamicTypeSize: .accessibility3, colorScheme: .light, scale: 3)
        XCTAssertEqual(light.color, "rgba(0,0,0,1.000)")
        XCTAssertEqual(dark.color, "rgba(255,255,255,1.000)")
        XCTAssertEqual(light.fontSize, 17)
        XCTAssertGreaterThan(large.fontSize, light.fontSize)
        XCTAssertNotEqual(light, dark)
    }
}
