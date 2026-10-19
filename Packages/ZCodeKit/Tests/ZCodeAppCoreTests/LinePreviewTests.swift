import Testing
import ZCodeAppCore

struct LinePreviewTests {
    func lines(_ count: Int, separator: String = "\n") -> String {
        (1...count).map { "ligne \($0)" }.joined(separator: separator)
    }

    @Test func texteVide() {
        #expect("".linePreview() == LinePreview(shown: "", totalLineCount: 0, hiddenLineCount: 0))
    }

    @Test func douzeLignesRienACacher() {
        let text = lines(12)
        let preview = text.linePreview()
        #expect(LinePreview.cardLineCount == 12)
        #expect(preview == LinePreview(shown: text, totalLineCount: 12, hiddenLineCount: 0))
    }

    @Test func finDeLigneFinaleNeComptePas() {
        let text = lines(12) + "\n"
        #expect(text.linePreview() == LinePreview(shown: text, totalLineCount: 12, hiddenLineCount: 0))
    }

    @Test func treizeLignesUneCachee() {
        let preview = lines(13).linePreview()
        #expect(preview == LinePreview(shown: lines(12), totalLineCount: 13, hiddenLineCount: 1))
    }

    @Test func finsDeLigneWindows() {
        let preview = (lines(13, separator: "\r\n") + "\r\n").linePreview()
        #expect(preview == LinePreview(shown: lines(12), totalLineCount: 13, hiddenLineCount: 1))
    }

    @Test func limiteChoisie() {
        let preview = "a\nb\n\nc".linePreview(maxLines: 2)
        #expect(preview == LinePreview(shown: "a\nb", totalLineCount: 4, hiddenLineCount: 2))
    }

    @Test func libelleDuBouton() {
        #expect(lines(34).linePreview().showAllLabel == "Afficher les 34 lignes")
    }
}
