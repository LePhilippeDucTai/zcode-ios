import Foundation
import Testing
import ZCodeAppCore

struct OfflineLabelsTests {
    let paris = TimeZone(identifier: "Europe/Paris")!
    // 17/10/2026 14:32 à Paris = 12:32 UTC
    let date = ISO8601DateFormatter().date(from: "2026-10-17T12:32:00Z")!

    @Test func horsLigne() {
        #expect(OfflineLabels.banner(savedAt: date, connecting: false, timeZone: paris) == "Hors ligne — copie du 17/10 à 14:32")
    }
    @Test func connexion() {
        #expect(OfflineLabels.banner(savedAt: date, connecting: true, timeZone: paris) == "Copie du 17/10 à 14:32 — connexion à l'hôte…")
    }
    @Test func taille() {
        #expect(OfflineLabels.size(0) == "Vide")
        // Espace insécable fine (U+202F) entre le nombre et l'unité.
        #expect(OfflineLabels.size(1_200_000) == "1,2\u{202F}Mo")
        #expect(OfflineLabels.size(340_000) == "340\u{202F}ko")
    }
}
