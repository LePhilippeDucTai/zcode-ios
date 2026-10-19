import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct UsageStatsClientTests {
    private let access = ProviderAccountAccess(accountType: "zai", mode: "individual-coding-plan", entitled: true)

    func connected(_ server: FakeZCodeServer) async -> ChannelClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return client
    }

    @Test func quotasDuCodingPlan() async throws {
        let server = FakeZCodeServer()
        let snapshot = try #require(try Fixtures.records(in: "v3.15.1/usage-entitlement").first).value
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let usage = UsageStatsClient(client: await connected(server))
        let result = try await usage.entitlement(providerId: "account:zai-individual-coding-plan", accountAccess: access)
        #expect(result.planName == "GLM Coding Max")
        #expect(result.limit(for: .fiveHours)?.remainingPercentage == 96)
        // Un seul argument objet ; ce fournisseur seulement, sans repli sur une clé d'environnement de l'hôte.
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot") == [.object([
            "includeSubscription": .bool(true), "preferredProviderId": .string("account:zai-individual-coding-plan"),
            "accountAccess": .object([
                "type": .string("zhipu-account"), "accountType": .string("zai"),
                "mode": .string("individual-coding-plan"), "entitled": .bool(true),
            ]),
            "requirePreferredProvider": .bool(true), "allowEnvApiKey": .bool(false),
        ])])
    }

    @Test func reponseIllisible() async throws {
        let server = FakeZCodeServer()
        await server.on("usage-stats.getEntitlementSnapshot") { _ in .string("?") }
        let usage = UsageStatsClient(client: await connected(server))
        await #expect(throws: AgentV4Error.self) {
            try await usage.entitlement(providerId: "account:zai-individual-coding-plan", accountAccess: access)
        }
    }

    // MARK: - Réinitialisations du Coding Plan

    private let scopeArguments: [String: JSONValue] = [
        "preferredProviderId": .string("account:zai-individual-coding-plan"),
        "accountAccess": .object([
            "type": .string("zhipu-account"), "accountType": .string("zai"),
            "mode": .string("individual-coding-plan"), "entitled": .bool(true),
        ]),
    ]

    @Test func statutDesReinitialisations() async throws {
        let server = FakeZCodeServer()
        let status = try Fixtures.recorded("v3.15.1/usage-reset/001-result-usage-stats.getCodingPlanResetStatus.json")
        await server.on("usage-stats.getCodingPlanResetStatus") { _ in status }
        let usage = UsageStatsClient(client: await connected(server))
        let result = try await usage.resetStatus(providerId: "account:zai-individual-coding-plan", accountAccess: access)
        #expect(result.availableFiveHourResets.count == 4)
        #expect(result.availableWeekResets.count == 4)
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus") == [.object(scopeArguments)])
    }

    @Test func demandeDOpportunaite() async throws {
        let server = FakeZCodeServer()
        let denied = try Fixtures.recorded("v3.15.1/usage-reset/002-result-usage-stats.requestCodingPlanResetOpportunity.json")
        await server.on("usage-stats.requestCodingPlanResetOpportunity") { _ in denied }
        let usage = UsageStatsClient(client: await connected(server))
        let result = try await usage.requestResetOpportunity(
            providerId: "account:zai-individual-coding-plan", accountAccess: access,
            idempotencyKey: "11111111-1111-4111-8111-111111111111")
        #expect(result.granted == false)
        #expect(result.nextTryAt != nil)
        #expect(await server.calls(to: "usage-stats.requestCodingPlanResetOpportunity") == [.object([
            "preferredProviderId": scopeArguments["preferredProviderId"]!,
            "accountAccess": scopeArguments["accountAccess"]!,
            "idempotencyKey": .string("11111111-1111-4111-8111-111111111111"),
        ])])
    }

    @Test func consommerUneReinitialisation() async throws {
        let server = FakeZCodeServer()
        await server.on("usage-stats.useCodingPlanReset") { _ in .object(["used": .bool(true)]) }
        let usage = UsageStatsClient(client: await connected(server))
        try await usage.useReset(providerId: "account:zai-individual-coding-plan", accountAccess: access,
                                 idempotencyKey: "22222222-2222-4222-8222-222222222222", type: .week)
        #expect(await server.calls(to: "usage-stats.useCodingPlanReset") == [.object([
            "preferredProviderId": scopeArguments["preferredProviderId"]!,
            "accountAccess": scopeArguments["accountAccess"]!,
            "idempotencyKey": .string("22222222-2222-4222-8222-222222222222"),
            "resetType": .string("WEEK"),
        ])])
    }

    @Test func consommationNonConfirmee() async throws {
        let server = FakeZCodeServer()
        await server.on("usage-stats.useCodingPlanReset") { _ in .object([:]) }
        let usage = UsageStatsClient(client: await connected(server))
        await #expect(throws: AgentV4Error.self) {
            try await usage.useReset(providerId: "account:zai-individual-coding-plan", accountAccess: access,
                                     idempotencyKey: "22222222-2222-4222-8222-222222222222", type: .fiveHour)
        }
    }

    @Test func curseurHistoriqueLu() async throws {
        let server = FakeZCodeServer()
        await server.on("usage-stats.markCodingPlanResetHistoryRead") { _ in .null }
        let usage = UsageStatsClient(client: await connected(server))
        try await usage.markResetHistoryRead(providerId: "account:zai-individual-coding-plan", accountAccess: access)
        #expect(await server.calls(to: "usage-stats.markCodingPlanResetHistoryRead") == [.object(scopeArguments)])
    }
}
