import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private func recorded(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/usage-entitlement").first { $0.file.hasPrefix(prefix) }).value
}

private func limit(_ type: String, unit: Int? = nil, number: Int? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string(type)]
    if let unit { object["unit"] = .number(Double(unit)) }
    if let number { object["number"] = .number(Double(number)) }
    return .object(object.merging(extra) { $1 })
}

struct UsageEntitlementTests {
    @Test func instantaneReelGLMCodingMax() throws {
        let snapshot = try UsageEntitlementSnapshot(json: recorded("001"))
        #expect(snapshot.authenticated)
        #expect(snapshot.unavailableReason == nil)
        #expect(snapshot.planName == "GLM Coding Max")
        #expect(snapshot.level == "max")
        #expect(snapshot.providerId == "account:zai-individual-coding-plan")
        #expect(snapshot.providerName == "Z.ai - Coding Plan")
        #expect(snapshot.generatedAt == Date(timeIntervalSince1970: 1_792_233_665.316))
        #expect(!snapshot.balanceHidden)
        #expect(!snapshot.isEmpty)

        // Deux fenêtres de crédits (Z.ai dit `CREDIT_LIMIT`) : `usage` est le plafond, `percentage` la part consommée.
        #expect(snapshot.limits.map(\.window) == [.fiveHours, .weekly])
        let fiveHours = try #require(snapshot.limit(for: .fiveHours))
        #expect(fiveHours.type == .creditLimit)
        #expect(fiveHours.total == 28_000)
        #expect(fiveHours.used == 1_149)
        #expect(fiveHours.remaining == 26_850)
        #expect(fiveHours.usedPercentage == 4)
        #expect(fiveHours.remainingPercentage == 96)
        #expect(fiveHours.usedFraction == 0.04)
        #expect(fiveHours.nextReset == Date(timeIntervalSince1970: 1_792_244_047.376))
        let weekly = try #require(snapshot.limit(for: .weekly))
        #expect(weekly.total == 140_000)
        #expect(weekly.used == 37_237)
        #expect(weekly.remainingPercentage == 74)
        #expect(weekly.nextReset == Date(timeIntervalSince1970: 1_792_586_212.983))
        #expect(snapshot.limit(for: .monthlyTools) == nil)

        // Le MCP officiel vient à part (`mcpQuota.aggregate`), affiché en dernier. Son champ `usage` vaut 0 : le total
        // se reconstruit par « consommé + restant ».
        let mcp = try #require(snapshot.limit(for: .mcp))
        #expect(mcp.type == .mcpUsageLimit)
        #expect(mcp.window == .mcp)
        #expect(mcp.total == 1_000)
        #expect(mcp.used == 0)
        #expect(mcp.remaining == 1_000)
        #expect(mcp.usedFraction == 0)
        #expect(snapshot.displayedLimits.map(\.window) == [.fiveHours, .weekly, .mcp])

        let subscription = try #require(snapshot.subscriptions.first)
        #expect(snapshot.subscriptions.count == 1)
        #expect(subscription.productName == "GLM Coding Max")
        #expect(subscription.productId == "product-1f179d")
        #expect(subscription.billingCycle == "annually")
        #expect(subscription.renewTime == Date(timeIntervalSince1970: 1_861_920_000))         // 2029-01-01T00:00:00Z
        #expect(subscription.expireTime == Date(timeIntervalSince1970: 1_893_499_200))        // 2030-01-01T12:00:00Z
    }

    @Test func sansCompteConfigure() throws {
        let snapshot = try UsageEntitlementSnapshot(json: recorded("002"))
        #expect(snapshot.authenticated)
        #expect(snapshot.unavailableReason == .notConfigured)
        #expect(snapshot.isEmpty)
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.limit(for: .mcp) == nil)
        #expect(snapshot.subscriptions.isEmpty)
        #expect(snapshot.planName == nil)
        #expect(snapshot.providerId == nil)
    }

    @Test func fenetresDeduitesCommeLeWeb() throws {
        let snapshot = try UsageEntitlementSnapshot(json: .object(["quota": .object(["limits": .array([
            limit("TOKENS_LIMIT", unit: 3, number: 5),                                        // BigModel : même sens
            limit("CREDIT_LIMIT", unit: 6, number: 1),
            limit("TIME_LIMIT", unit: 5, number: 1),
            limit("TOKENS_LIMIT", unit: 4),                                                   // fenêtre inconnue
            limit("SOMETHING_NEW"),                                                           // type inconnu : gardé
            .object(["unit": .number(3)]),                                                    // sans type : écarté
        ])])]))
        #expect(snapshot.limits.map(\.window) == [.fiveHours, .weekly, .monthlyTools, .other, .other])
        #expect(snapshot.limits.map(\.type.rawValue).last == "SOMETHING_NEW")
        #expect(snapshot.displayedLimits.map(\.window) == [.fiveHours, .weekly, .monthlyTools, .other, .other])
        #expect(snapshot.level == nil)
        #expect(!snapshot.isEmpty)
    }

    @Test func pourcentagesEtFractionsBornes() throws {
        let overflow = try #require(UsageQuotaLimit(json: limit("CREDIT_LIMIT", extra: ["percentage": .number(130)])))
        #expect(overflow.remainingPercentage == 0)
        #expect(overflow.usedFraction == 1)
        let amountsOnly = try #require(UsageQuotaLimit(json: limit("CREDIT_LIMIT", extra: [
            "usage": .number(200), "currentValue": .number(50),
        ])))
        #expect(amountsOnly.remainingPercentage == nil)                                       // pas de pourcentage
        #expect(amountsOnly.usedFraction == 0.25)                                             // calculé sur les montants
        let bare = try #require(UsageQuotaLimit(json: limit("CREDIT_LIMIT")))
        #expect(bare.usedFraction == 0)
        #expect(bare.nextReset == nil)
        #expect(UsageQuotaLimit(json: .object(["type": .string("")])) == nil)
        #expect(UsageQuotaLimit(json: nil) == nil)
    }

    @Test func tolerantAuxChampsAbsents() throws {
        let empty = try UsageEntitlementSnapshot(json: .object([:]))
        #expect(!empty.authenticated)
        #expect(empty.isEmpty)
        #expect(empty.unavailableReason == nil)
        #expect(empty.displayedLimits.isEmpty)
        let blankNames = try UsageEntitlementSnapshot(json: .object([
            "context": .object(["displayName": .string("  ")]), "quota": .object(["level": .string("")]),
            "remaining": .object(["isShow": .bool(false)]),
            "subscription": .object(["details": .array([.object(["productId": .string("p-1")]), .object([:])])]),
        ]))
        #expect(blankNames.planName == nil)
        #expect(blankNames.level == nil)
        #expect(blankNames.balanceHidden)
        #expect(blankNames.subscriptions.map(\.productName) == ["p-1"])                       // nom absent : identifiant
        #expect(throws: V4DecodingError.self) { try UsageEntitlementSnapshot(json: .array([])) }
    }
}
