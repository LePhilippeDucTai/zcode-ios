import XCTest
@testable import ZCode

/// Rendu réel par KaTeX embarqué (simulateur iPhone 18 Pro, échelle 3).
@MainActor
final class FormulaRendererTests: XCTestCase {
    private func key(_ latex: String, display: Bool = false) -> FormulaKey {
        FormulaKey(latex: latex, display: display, fontSize: 17, color: "rgba(0,0,0,1.000)", scale: 3)
    }

    func testFractionEnImage() async {
        let result = await FormulaRenderer.shared.render(key(#"\frac{\frac{a}{b}}{\frac{c}{d}}"#))
        guard case .image(let formula) = result else { return XCTFail("image attendue : \(result)") }
        XCTAssertGreaterThan(formula.image.size.width, 5)
        XCTAssertGreaterThan(formula.image.size.height, 34)              // entière, pas rognée à la boîte de la police
        XCTAssertEqual(formula.image.scale, 3, accuracy: 0.05)
        XCTAssertGreaterThan(ImagePixels.maxAlpha(formula.image), 200)   // encre visible
        XCTAssertEqual(ImagePixels.cornerAlpha(formula.image), 0)        // fond transparent : rien de blanc en sombre
    }

    func testExposantEtCache() async {
        let square = key("x^2")
        let result = await FormulaRenderer.shared.render(square)
        guard case .image(let formula) = result else { return XCTFail("image attendue : \(result)") }
        guard case .image? = FormulaRenderer.shared.cached(square) else { return XCTFail("image attendue en cache") }
        // Même `x^2` descend un peu (interligne de KaTeX, marge de 2 pt) : la fraction double, nettement plus
        // (écart mesuré : 4,7 pt).
        let deepResult = await FormulaRenderer.shared.render(key(#"\frac{\frac{a}{b}}{\frac{c}{d}}"#))
        guard case .image(let deep) = deepResult else { return XCTFail("image attendue : \(deepResult)") }
        XCTAssertGreaterThan(deep.depth, formula.depth + 4)
    }

    func testFormuleFautiveEnRepli() async {
        let broken = key(#"\frac{a"#)
        guard case .failed = await FormulaRenderer.shared.render(broken) else { return XCTFail("repli attendu") }
        guard case .failed? = FormulaRenderer.shared.cached(broken) else { return XCTFail("repli attendu en cache") }
    }

    func testBlocSansProfondeur() async {
        let result = await FormulaRenderer.shared.render(key(#"\sum_{i=1}^{n} i"#, display: true))
        guard case .image(let formula) = result else { return XCTFail("image attendue : \(result)") }
        XCTAssertEqual(formula.depth, 0)
    }

    func testDemandesSimultanees() async {
        // `async let` refusé ici par Swift 6 (envoi de `self`) : deux tâches, repli prévu par le brief.
        let firstKey = key("a_1"), secondKey = key("b_2")
        let first = Task { @MainActor in await FormulaRenderer.shared.render(firstKey) }
        let second = Task { @MainActor in await FormulaRenderer.shared.render(secondKey) }
        let a = await first.value, b = await second.value
        guard case .image = a, case .image = b else { return XCTFail("deux images attendues : \(a), \(b)") }
    }

    /// Plus large que la vue (1024 pt) : la vue est élargie, la formule peinte jusqu'au bout. Le critère « encre à
    /// droite » n'a de sens que sur une formule large (la marge de 2 pt dépasse 10 % de la largeur d'une fraction).
    /// 60 termes : environ 3 200 pt, sous `FormulaRenderer.maxCaptureSide` (120 termes mesuraient 6 348 pt).
    func testFormuleLargePeinteJusquauBout() async {
        let latex = (1...60).map { "x_{\($0)}" }.joined(separator: "+")
        let result = await FormulaRenderer.shared.render(key(latex, display: true))
        guard case .image(let formula) = result else { return XCTFail("image attendue : \(result)") }
        XCTAssertGreaterThan(formula.image.size.width, 1024)
        XCTAssertGreaterThan(ImagePixels.maxAlpha(rightOf: 0.9, of: formula.image), 200)
    }

    /// Formule démesurée (plus de 10 000 pt de côté, ou presque carrée au-delà de la surface) : refusée sans capture,
    /// en repli gris gardé en cache. Les limites laissent passer une formule large légitime (30 sommes en bloc :
    /// 2 363 pt mesurés).
    func testFormuleGeanteRefuseeSansCapture() async {
        let renderer = FormulaRenderer.shared
        XCTAssertGreaterThan(FormulaRenderer.maxCaptureSide, 2363)
        let wide = String(repeating: #"\sum_{i=1}^{n} x_i^2 + "#, count: 30) + "1"
        let wideResult = await renderer.render(key(wide, display: true))
        guard case .image(let wideFormula) = wideResult else { return XCTFail("image attendue : \(wideResult)") }
        XCTAssertGreaterThan(wideFormula.image.size.width, 2000)
        let giant = key(#"\rule{500em}{500em}"#)
        let captures = renderer.captureCount
        guard case .failed = await renderer.render(giant) else { return XCTFail("repli attendu") }
        XCTAssertEqual(renderer.captureCount, captures, "une formule démesurée ne doit pas être capturée")
        guard case .failed? = renderer.cached(giant) else { return XCTFail("repli attendu en cache") }
        // Presque carrée, sous le plafond par côté (150em ≈ 3 086 pt) mais au-dessus de la surface (≈ 86 Mpx à
        // l'échelle 3) : refusée aussi sans capture.
        let square = key(#"\rule{150em}{150em}"#)
        guard case .failed = await renderer.render(square) else { return XCTFail("repli attendu (surface)") }
        XCTAssertEqual(renderer.captureCount, captures, "une formule trop grande en surface ne doit pas être capturée")
        let after = await renderer.render(key("z_1"))                    // le moteur reste utilisable
        guard case .image = after else { return XCTFail("image attendue après le refus : \(after)") }
    }

    /// Un rendu qui dépasse le délai rend la main en repli, sans être gardé : la file repart, et la même formule
    /// est rendue normalement à la demande suivante.
    func testDelaiDepasseEnRepliNonGardePuisNouvelEssai() async {
        let renderer = FormulaRenderer.shared
        let slowKey = key(#"\sqrt{\delta_{lent}}"#)
        _ = await renderer.render(key("y_0"))                            // page déjà chargée : seul le rendu est borné
        let normal = renderer.renderTimeout
        renderer.renderTimeout = .milliseconds(1)                       // aucun aller-retour JavaScript n'y tient
        let slow = await renderer.render(slowKey)
        renderer.renderTimeout = normal
        guard case .unavailable = slow else { return XCTFail("repli non gardé attendu : \(slow)") }
        XCTAssertNil(renderer.cached(slowKey), "un délai dépassé ne doit pas rester en cache")
        let retry = await renderer.render(slowKey)
        guard case .image = retry else { return XCTFail("image attendue au nouvel essai : \(retry)") }
    }
}
