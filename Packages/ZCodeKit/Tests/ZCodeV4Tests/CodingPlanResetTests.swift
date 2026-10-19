import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct CodingPlanResetTests {
    @Test func statutReelDuCompte() throws {
        let json = try Fixtures.recorded("v3.15.1/usage-reset/001-result-usage-stats.getCodingPlanResetStatus.json")
        let status = try CodingPlanResetStatus(json: json)
        #expect(status.availableFiveHourResets.count == 4)
        #expect(status.availableWeekResets.count == 4)
        #expect(status.latestFiveHourResetUsedAt == nil)
        #expect(status.latestWeekResetUsedAt == nil)
        #expect(status.hasUnreadHistory == false)
        // Même échéance pour toutes les opportunités du compte réel.
        #expect(status.availableFiveHourResets.map(\.expireAt).allSatisfy { $0 == status.availableFiveHourResets.first?.expireAt })
        #expect(status.opportunities(for: .fiveHour).count == 4)
        #expect(status.opportunities(for: .week).count == 4)
        #expect(status.latestUsedAt(for: .week) == nil)
        #expect(status.isEmpty == false)
    }

    @Test func refusDOpportunauteReel() throws {
        let json = try Fixtures.recorded("v3.15.1/usage-reset/002-result-usage-stats.requestCodingPlanResetOpportunity.json")
        let result = CodingPlanResetOpportunityResult(json: json)
        #expect(result.granted == false)
        #expect(result.nextTryAt == Date(timeIntervalSince1970: 1_792_357_191.181))
    }

    @Test func opportunaiteAccordee() {
        let result = CodingPlanResetOpportunityResult(json: .object(["granted": .bool(true)]))
        #expect(result == CodingPlanResetOpportunityResult(granted: true, nextTryAt: nil))
    }

    @Test func decodageTolerant() throws {
        // Champs absents ou nuls : listes vides, dates nil, pas d'erreur (un compte sans réinitialisation reste lisible).
        let empty = try CodingPlanResetStatus(json: .object([
            "availableFiveHourResets": .array([]),
            "availableWeekResets": .array([]),
            "latestFiveHourResetHistory": .null,
            "latestWeekResetHistory": .null,
            "hasUnreadHistory": .bool(false),
        ]))
        #expect(empty.isEmpty == true)
        let bare = try CodingPlanResetStatus(json: .object([:]))
        #expect(bare.isEmpty == true)
        #expect(bare.hasUnreadHistory == false)
        // Une opportunité illisible est écartée, pas la réponse entière.
        let mixed = try CodingPlanResetStatus(json: .object([
            "availableFiveHourResets": .array([.object(["expireAt": .number(1_794_475_959_000)]), .object(["expireAt": .number(0)]), .string("?")]),
        ]))
        #expect(mixed.availableFiveHourResets.count == 1)
        #expect(mixed.availableFiveHourResets.first?.expireAt == Date(timeIntervalSince1970: 1_794_475_959))
        // Historique consommé lu en époques millisecondes.
        let used = try CodingPlanResetStatus(json: .object([
            "latestFiveHourResetHistory": .object(["usedAt": .number(1_792_240_000_000)]),
            "hasUnreadHistory": .bool(true),
        ]))
        #expect(used.latestUsedAt(for: .fiveHour) == Date(timeIntervalSince1970: 1_792_240_000))
        #expect(used.latestUsedAt(for: .week) == nil)
        #expect(used.hasUnreadHistory == true)
    }

    @Test func reponseStructurellementInutilisable() {
        #expect(throws: V4DecodingError.self) { try CodingPlanResetStatus(json: .string("?")) }
        #expect(throws: V4DecodingError.self) { try CodingPlanResetStatus(json: .array([])) }
    }
}
