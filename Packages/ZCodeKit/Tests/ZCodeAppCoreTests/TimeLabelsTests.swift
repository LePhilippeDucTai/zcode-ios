import Foundation
import Testing
import ZCodeAppCore

/// Paris, en français ; `now` = mardi 13 octobre 2026, 15:00:00 (heure de Paris).
struct TimeLabelsTests {
    let labels = TimeLabels(timeZone: TimeZone(identifier: "Europe/Paris")!, locale: Locale(identifier: "fr_FR"))
    let now = Date(timeIntervalSince1970: 1_791_896_400)                     // 2026-10-13 15:00:00 +02:00

    func ms(_ secondsBeforeNow: Double) -> Double { (now.timeIntervalSince1970 - secondsBeforeNow) * 1000 }

    @Test func relatifCourt() {
        #expect(labels.relative(ms(0), now: now) == "à l'instant")
        #expect(labels.relative(ms(59.9), now: now) == "à l'instant")
        #expect(labels.relative(ms(60), now: now) == "il y a 1 min")
        #expect(labels.relative(ms(12 * 60 + 59), now: now) == "il y a 12 min")
        #expect(labels.relative(ms(3599), now: now) == "il y a 59 min")
    }

    @Test func relatifEnHeures() {
        #expect(labels.relative(ms(3600), now: now) == "il y a 1 h")
        #expect(labels.relative(ms(3 * 3600 + 12 * 60), now: now) == "il y a 3 h 12")
        #expect(labels.relative(ms(3 * 3600 + 5 * 60 + 30), now: now) == "il y a 3 h 05")
        #expect(labels.relative(ms(24 * 3600 - 1), now: now) == "il y a 23 h 59")
    }

    @Test func relatifFutur() {
        #expect(labels.relative(ms(-120), now: now) == "à l'instant")       // hôte en avance de 2 min
    }

    @Test func hierEtDates() {
        // 25 h avant 15:00 le 13 = 14:00 le 12 : veille.
        #expect(labels.relative(ms(25 * 3600), now: now) == "hier 14:00")
        // 39 h avant = 00:00 le 12 : veille encore.
        #expect(labels.relative(ms(39 * 3600), now: now) == "hier 00:00")
        // 39 h 01 avant = 23:59 le 11 : avant-veille.
        #expect(labels.relative(ms(39 * 3600 + 60), now: now) == "dim. 11 oct., 23:59")
        // Autre année.
        let lastYear = Date(timeIntervalSince1970: 1_760_352_000).timeIntervalSince1970 * 1000   // 2025-10-13 12:40 +02:00
        #expect(labels.relative(lastYear, now: now) == "13 oct. 2025, 12:40")
    }

    @Test func veilleMaisMoinsDe24Heures() {
        // Maintenant = 00:30 le 14 ; 23 h 50 avant = 00:40 le 13 : la règle des 24 h passe avant « hier ».
        let midnight = Date(timeIntervalSince1970: 1_791_930_600)          // 2026-10-14 00:30:00 +02:00
        let stamp = (midnight.timeIntervalSince1970 - (23 * 3600 + 50 * 60)) * 1000
        #expect(labels.relative(stamp, now: midnight) == "il y a 23 h 50")
    }

    @Test func exactEtHorloge() {
        let stamp = 1_791_885_161_427.0                                      // fixture `conversation` : 11:52:41,427
        #expect(labels.exact(stamp, now: now) == "mardi 13 octobre, 11:52:41")
        #expect(labels.clock(stamp) == "11:52:41")
        let lastYear = 1_760_352_000_000.0
        #expect(labels.exact(lastYear, now: now) == "lundi 13 octobre 2025, 12:40:00")
    }

    @Test func creation() {
        #expect(labels.created(ms(10), now: now) == "créée à l'instant")
        #expect(labels.created(ms(3 * 3600 + 12 * 60), now: now) == "créée il y a 3 h 12")
        #expect(labels.created(ms(25 * 3600), now: now) == "créée hier 14:00")
        #expect(labels.created(ms(39 * 3600 + 60), now: now) == "créée le dim. 11 oct., 23:59")
    }

    @Test func dureesDeCarte() {
        #expect(TimeLabels.toolDuration(milliseconds: 0) == "< 1 s")
        #expect(TimeLabels.toolDuration(milliseconds: 999) == "< 1 s")
        #expect(TimeLabels.toolDuration(milliseconds: 1000) == "1,0 s")
        #expect(TimeLabels.toolDuration(milliseconds: 3_299) == "3,2 s")             // tronqué, jamais arrondi au-dessus
        #expect(TimeLabels.toolDuration(milliseconds: 9_999) == "9,9 s")
        #expect(TimeLabels.toolDuration(milliseconds: 10_000) == "10 s")
        #expect(TimeLabels.toolDuration(milliseconds: 42_900) == "42 s")
        #expect(TimeLabels.toolDuration(milliseconds: 125_000) == "2 min 05 s")
        #expect(TimeLabels.toolDuration(milliseconds: 3_599_999) == "59 min 59 s")
        #expect(TimeLabels.toolDuration(milliseconds: 3_840_000) == "1 h 04 min")
    }

    @Test func dureeNegative() {
        #expect(TimeLabels.toolDuration(milliseconds: -5_000) == "< 1 s")
        #expect(TimeLabels.workDuration(milliseconds: -5_000) == "0 s")
    }

    @Test func dureesDeTravail() {
        #expect(TimeLabels.workDuration(milliseconds: 9_649) == "9 s")                // fixture `send-text-long`
        #expect(TimeLabels.workDuration(milliseconds: 59_999) == "59 s")
        #expect(TimeLabels.workDuration(milliseconds: 60_000) == "1 min")
        #expect(TimeLabels.workDuration(milliseconds: 47 * 60_000 + 59_000) == "47 min")
        #expect(TimeLabels.workDuration(milliseconds: 3_840_000) == "1 h 04")
        #expect(TimeLabels.workDuration(milliseconds: 2 * 3_600_000) == "2 h 00")
    }
}
