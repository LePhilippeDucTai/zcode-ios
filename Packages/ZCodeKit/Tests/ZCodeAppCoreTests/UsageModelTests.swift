import Foundation
import Synchronization
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Vue réelle du catalogue : un seul fournisseur, `account:zai-individual-coding-plan`, avec son accès par compte.
private func realCatalogView() throws -> JSONValue {
    try Fixtures.recorded("v3.15.1/handshake-sessions/005-result-model-selection.getView.json")
}

/// Vue réelle complétée d'un second compte (BigModel, équipe) et d'un fournisseur à clé.
private func twoAccountsView() throws -> JSONValue {
    var view = try #require(realCatalogView().objectValue)
    var providers = view["providers"]?.arrayValue ?? []
    providers.append(.object([
        "providerId": .string("account:bigmodel-team-coding-plan"), "providerName": .string("BigModel Team"),
        "config": .object(["access": .object([
            "type": .string("zhipu-account"), "accountType": .string("bigmodel"), "mode": .string("team-coding-plan"),
            "entitled": .bool(true),
        ])]),
        "models": .array([.object(["modelId": .string("GLM-5.3")])]),
    ]))
    providers.append(.object([
        "providerId": .string("new-provider"), "providerName": .string("Mistral"),
        "config": .object(["access": .object(["type": .string("api-key"), "apiKey": .string("cle-factice")])]),
        "models": .array([.object(["modelId": .string("mistral-large-4")])]),
    ]))
    view["providers"] = .array(providers)
    return .object(view)
}

private func usageRecord(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/usage-entitlement").first { $0.file.hasPrefix(prefix) }).value
}

private let fixedNow = Date(timeIntervalSince1970: 1_792_240_000)

/// Horloge réglable des tests (`now` du modèle).
private final class Clock: Sendable {
    private let value = Mutex(fixedNow)
    var now: Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Réponse minimale : une fenêtre de 5 h consommée à `usedPercentage` %, et la semaine à `weeklyUsedPercentage` % si donnée.
private func fiveHoursSnapshot(usedPercentage: Double, weeklyUsedPercentage: Double? = nil,
                               hidden: Bool = false) throws -> UsageEntitlementSnapshot {
    var limits: [JSONValue] = [.object([
        "type": .string("CREDIT_LIMIT"), "unit": .number(3), "number": .number(5),
        "percentage": .number(usedPercentage),
    ])]
    if let weeklyUsedPercentage {
        limits.append(.object([
            "type": .string("CREDIT_LIMIT"), "unit": .number(6), "number": .number(1),
            "percentage": .number(weeklyUsedPercentage),
        ]))
    }
    var object: [String: JSONValue] = [
        "authenticated": .bool(true),
        "quota": .object(["limits": .array(limits)]),
    ]
    if hidden { object["remaining"] = .object(["isShow": .bool(false)]) }
    return try UsageEntitlementSnapshot(json: .object(object))
}

struct ComposerQuotaTests {
    @Test func deuxAnneaux() throws {
        let quota = try #require(UsageLabels.composerQuota(
            fiveHoursSnapshot(usedPercentage: 39, weeklyUsedPercentage: 20)))
        #expect(quota.fiveHours.percent == 61)
        #expect(quota.fiveHours.fraction == 0.61)
        #expect(quota.fiveHours.level == .normal)
        let weekly = try #require(quota.weekly)
        #expect(weekly.percent == 80)
        #expect(weekly.fraction == 0.8)
        #expect(weekly.level == .normal)
        #expect(quota.text == "61 %")
        #expect(quota.accessibilityLabel == "Quota restant : 61 % sur 5 heures, 80 % sur la semaine")
        #expect(quota.percent == 61)                                                          // compatibilité
        #expect(quota.level == .normal)
    }

    @Test func niveauxParAnneau() throws {
        let rounded = try #require(UsageLabels.composerQuota(
            fiveHoursSnapshot(usedPercentage: 80.4, weeklyUsedPercentage: 85)))
        #expect(rounded.fiveHours.percent == 20)                                              // 19,6 → 20 %
        #expect(rounded.fiveHours.level == .normal)
        #expect(rounded.weekly?.percent == 15)
        #expect(rounded.weekly?.level == .low)

        let critical = try #require(UsageLabels.composerQuota(fiveHoursSnapshot(usedPercentage: 95.6)))
        #expect(critical.fiveHours.percent == 4)                                              // 4,4 → 4 %
        #expect(critical.fiveHours.level == .critical)
        #expect(critical.level == .critical)
        #expect(critical.fiveHours.fraction == 0.04)
    }

    @Test func sansSemaineUnSeulAnneau() throws {
        let quota = try #require(UsageLabels.composerQuota(fiveHoursSnapshot(usedPercentage: 39)))
        #expect(quota.weekly == nil)
        #expect(quota.fiveHours.percent == 61)
        #expect(quota.accessibilityLabel == "Quota restant : 61 % sur 5 heures")
    }

    @Test func fenetreEntierementConsommee() throws {
        let quota = try #require(UsageLabels.composerQuota(fiveHoursSnapshot(usedPercentage: 100)))
        #expect(quota.fiveHours.percent == 0)
        #expect(quota.fiveHours.fraction == 0)
        #expect(quota.fiveHours.level == .critical)
    }

    @Test func rienAMontrer() throws {
        #expect(UsageLabels.composerQuota(nil) == nil)                             // pas encore lu
        #expect(try UsageLabels.composerQuota(fiveHoursSnapshot(usedPercentage: 10, hidden: true)) == nil)
        let noWindow = try UsageEntitlementSnapshot(json: .object(["authenticated": .bool(true)]))
        #expect(UsageLabels.composerQuota(noWindow) == nil)
    }
}

@MainActor
struct UsageModelTests {
    private func makeUsage(_ servers: ServerQueue, clock: Clock = Clock()) -> UsageModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        return UsageModel(connection: connection, catalog: ModelCatalog(connection: connection), now: { clock.now })
    }

    /// Modèle prêt (`phase == .ready`) sur la réponse réelle `usage-entitlement`, compte préféré du catalogue réel.
    private func readyUsage() async throws -> UsageModel {
        let server = try await readyServer()
        let view = try realCatalogView()
        let snapshot = try usageRecord("001")
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let usage = makeUsage(ServerQueue([server]))
        await usage.loadIfNeeded()
        #expect(usage.phase == .ready)
        return usage
    }

    @Test func restantDeLaFenetreDeCinqHeures() async throws {
        let usage = try await readyUsage()
        let snapshot = try #require(usage.snapshot)
        let five = try #require(snapshot.limit(for: .fiveHours))
        #expect(usage.fiveHoursRemaining == five.remainingPercentage)
        #expect(usage.fiveHoursRemaining == 96)
    }

    @Test func sansFenetreDeCinqHeures() async throws {
        let usage = makeUsage(ServerQueue([]))
        #expect(usage.fiveHoursRemaining == nil)                                  // rien lu
    }

    @Test func lectureDesQuotasDuComptePrefere() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        let snapshot = try usageRecord("001")
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let usage = makeUsage(ServerQueue([server]))
        #expect(usage.phase == .idle)
        await usage.loadIfNeeded()
        #expect(usage.phase == .ready)
        #expect(usage.snapshot?.planName == "GLM Coding Max")
        #expect(usage.snapshot?.limit(for: .fiveHours)?.remainingPercentage == 96)
        #expect(usage.updatedAt == fixedNow)
        #expect(usage.provider?.providerId == "account:zai-individual-coding-plan")
        #expect(usage.providers.map(\.providerId) == ["account:zai-individual-coding-plan"])
        // L'accès par compte lu dans le catalogue est renvoyé tel quel à l'hôte.
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot") == [.object([
            "includeSubscription": .bool(true), "preferredProviderId": .string("account:zai-individual-coding-plan"),
            "accountAccess": .object([
                "type": .string("zhipu-account"), "accountType": .string("zai"),
                "mode": .string("individual-coding-plan"), "entitled": .bool(true),
            ]),
            "requirePreferredProvider": .bool(true), "allowEnvApiKey": .bool(false),
        ])])
        await usage.loadIfNeeded()                                             // réponse récente : rien à relire
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 1)
        await usage.refresh()                                                  // bouton ou tirer pour actualiser
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 2)
        #expect(usage.phase == .ready)
    }

    @Test func reouvertureRelitUneReponseAncienne() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        let snapshot = try usageRecord("001")
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let clock = Clock()
        let usage = makeUsage(ServerQueue([server]), clock: clock)
        await usage.loadIfNeeded()
        clock.advance(by: 59)
        await usage.loadIfNeeded()                                             // encore fraîche
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 1)
        clock.advance(by: 2)
        await usage.loadIfNeeded()                                             // plus d'une minute : relue
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 2)
        #expect(usage.updatedAt == clock.now)
    }

    @Test func reponseSansQuotaRestePrete() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        let snapshot = try usageRecord("002")
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(usage.phase == .ready)
        #expect(usage.snapshot?.unavailableReason == .notConfigured)
        #expect(usage.snapshot?.isEmpty == true)
    }

    @Test func aucunCompteDansLeCatalogue() async throws {
        let server = try await readyServer()
        let view = try Fixtures.file("synthetic/model-selection-mistral.json")   // accès zai incomplet, Mistral à clé
        await server.on("model-selection.getView") { _ in view }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(usage.phase == .noAccount)
        #expect(usage.providers.isEmpty)
        #expect(usage.snapshot == nil)
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").isEmpty)
    }

    @Test func catalogueIllisible() async throws {
        struct Unavailable: Error {}
        let server = try await readyServer()
        await server.on("model-selection.getView") { _ in throw Unavailable() }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        guard case .failed(let message) = usage.phase else { Issue.record("échec attendu : \(usage.phase)"); return }
        #expect(message.hasPrefix("Liste des modèles indisponible"))
    }

    @Test func echecPuisNouvelEssai() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        let snapshot = try usageRecord("001")
        let counter = Counter()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in
            if counter.next() == 1 { throw RPCTestError(message: "Coding Plan entitlement refresh failed") }
            return snapshot
        }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        guard case .failed(let message) = usage.phase else { Issue.record("échec attendu : \(usage.phase)"); return }
        #expect(message.hasPrefix("Utilisation indisponible : "))
        #expect(message.contains("abonnement illisible"))
        #expect(usage.snapshot == nil)
        await usage.refresh()
        #expect(usage.phase == .ready)
        #expect(usage.snapshot?.planName == "GLM Coding Max")
    }

    @Test func hoteInjoignable() async throws {
        let usage = makeUsage(ServerQueue([]))
        await usage.refresh()
        guard case .failed(let message) = usage.phase else { Issue.record("échec attendu : \(usage.phase)"); return }
        #expect(message.hasPrefix("Hôte injoignable"))
    }

    @Test func choixDuCompte() async throws {
        let server = try await readyServer()
        let view = try twoAccountsView()
        let snapshot = try usageRecord("001")
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in snapshot }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(usage.providers.map(\.providerId) == ["account:zai-individual-coding-plan", "account:bigmodel-team-coding-plan"])
        #expect(usage.provider?.providerId == "account:zai-individual-coding-plan")   // sélection préférée de l'hôte
        await usage.select(providerId: "account:bigmodel-team-coding-plan")
        #expect(usage.provider?.providerId == "account:bigmodel-team-coding-plan")
        let calls = await server.calls(to: "usage-stats.getEntitlementSnapshot")
        #expect(calls.count == 2)
        #expect(calls.last?["preferredProviderId"] == .string("account:bigmodel-team-coding-plan"))
        #expect(calls.last?["accountAccess"]?["accountType"] == .string("bigmodel"))
        await usage.select(providerId: "account:bigmodel-team-coding-plan")      // déjà choisi : rien
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 2)
    }
}

/// Fausses réponses de réinitialisation : statut réel (4 + 4 opportunités, jamais consommées) et dérivés.
private func resetStatusJSON(fiveHour: Int = 4, week: Int = 4, usedAt: Double? = nil,
                             unread: Bool = false) -> JSONValue {
    .object([
        "availableFiveHourResets": .array((0..<fiveHour).map { _ in .object(["expireAt": .number(1_794_475_959_000)]) }),
        "availableWeekResets": .array((0..<week).map { _ in .object(["expireAt": .number(1_794_475_959_000)]) }),
        "latestFiveHourResetHistory": usedAt.map { .object(["usedAt": .number($0)]) } ?? .null,
        "latestWeekResetHistory": .null,
        "hasUnreadHistory": .bool(unread),
    ])
}

private let usedAtMs = 1_792_240_123_000.0

@MainActor
struct UsageResetTests {
    private func makeUsage(_ servers: ServerQueue,
                           pause: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> UsageModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        return UsageModel(connection: connection, catalog: ModelCatalog(connection: connection), now: { fixedNow }, pause: pause)
    }

    /// Modèle prêt sur le catalogue réel, avec statut et opportunité de réinitialisation répondus. Le gestionnaire de
    /// statut reçoit le numéro de lecture (0 : lecture initiale).
    private func readyUsage(status: @escaping @Sendable (Int) -> JSONValue = { _ in resetStatusJSON() },
                            snapshot: JSONValue? = nil) async throws -> (UsageModel, FakeZCodeServer) {
        let server = try await readyServer()
        let view = try realCatalogView()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in
            if let snapshot { return snapshot }
            return try usageRecord("001")
        }
        let reads = Counter()
        await server.on("usage-stats.getCodingPlanResetStatus") { _ in status(reads.next() - 1) }
        await server.on("usage-stats.requestCodingPlanResetOpportunity") { _ in .object(["granted": .bool(false), "nextTryAt": .number(1_792_357_191_181)]) }
        let usage = makeUsage(ServerQueue([server]))
        await usage.loadIfNeeded()
        #expect(usage.phase == .ready)
        return (usage, server)
    }

    @Test func lectureDuStatutEtRefusDOpportunaite() async throws {
        let (usage, server) = try await readyUsage()
        #expect(usage.resetStatus?.availableFiveHourResets.count == 4)
        #expect(usage.resetStatus?.availableWeekResets.count == 4)
        #expect(usage.resetIssue == nil)
        // Une opportunité refusée ne relit pas le statut ; une seule demande d'éligibilité par lecture.
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus").count == 1)
        #expect(await server.calls(to: "usage-stats.requestCodingPlanResetOpportunity").count == 1)
        let key = try #require(await server.calls(to: "usage-stats.requestCodingPlanResetOpportunity").first?["idempotencyKey"]?.stringValue)
        #expect(key.count == 36)   // UUID : la clé d'idempotence de l'hôte est bornée à 64 caractères
    }

    @Test func opportunaiteAccordeeRelitLeStatut() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in try usageRecord("001") }
        await server.on("usage-stats.getCodingPlanResetStatus") { _ in resetStatusJSON(fiveHour: 0, week: 0) }
        await server.on("usage-stats.requestCodingPlanResetOpportunity") { _ in .object(["granted": .bool(true)]) }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus").count == 2)
        #expect(usage.resetStatus?.isEmpty == true)
    }

    @Test func echecDeLectureSansJaugesMasquees() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in try usageRecord("001") }
        let counter = Counter()
        await server.on("usage-stats.getCodingPlanResetStatus") { _ in
            if counter.next() == 1 { throw RPCTestError(message: "coding_plan_reset_zcode_jwt_required") }
            return resetStatusJSON()
        }
        await server.on("usage-stats.requestCodingPlanResetOpportunity") { _ in .object(["granted": .bool(true)]) }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(usage.phase == .ready)                                   // les jauges restent affichées
        #expect(usage.resetIssue == "Reconnecte le Coding Plan dans ZCode sur l'hôte, puis réessaie.")
        #expect(usage.resetStatus == nil)
        await usage.refresh()                                            // l'erreur ne colle pas : la suivante passe
        #expect(usage.resetIssue == nil)
        #expect(usage.resetStatus?.availableFiveHourResets.count == 4)
    }

    @Test func limiteDeDebitDOpportunaiteTolerée() async throws {
        let server = try await readyServer()
        let view = try realCatalogView()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in try usageRecord("001") }
        await server.on("usage-stats.getCodingPlanResetStatus") { _ in resetStatusJSON() }
        await server.on("usage-stats.requestCodingPlanResetOpportunity") { _ in
            throw RPCTestError(message: "coding_plan_reset_opportunity_throttled")
        }
        let usage = makeUsage(ServerQueue([server]))
        await usage.refresh()
        #expect(usage.resetIssue == nil)                                 // le statut lu suffit
        #expect(usage.resetStatus?.availableFiveHourResets.count == 4)
    }

    @Test func consommationConfirméeParLHistorique() async throws {
        // Après le `use`, la 2e lecture de statut montre la consommation : 3 opportunités et un historique.
        let (usage, server) = try await readyUsage(status: { read in
            read == 0 ? resetStatusJSON() : resetStatusJSON(fiveHour: 3, week: 4, usedAt: usedAtMs, unread: true)
        })
        await server.on("usage-stats.useCodingPlanReset") { _ in .object(["used": .bool(true)]) }
        await usage.useReset(.fiveHour)
        #expect(usage.isResetting == false)
        #expect(usage.resetNotice == "Fenêtre de 5 heures réinitialisée.")
        #expect(usage.resetError == nil)
        let useCalls = await server.calls(to: "usage-stats.useCodingPlanReset")
        #expect(useCalls.count == 1)
        #expect(useCalls.first?["resetType"] == .string("FIVE_HOUR"))
        #expect(try #require(useCalls.first?["idempotencyKey"]?.stringValue).count == 36)
        // Statut relu jusqu'à la confirmation, historique marqué lu, jauges relues.
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus").count >= 2)
        #expect(await server.calls(to: "usage-stats.markCodingPlanResetHistoryRead").count == 1)
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 2)
        #expect(usage.resetStatus?.availableFiveHourResets.count == 3)
        #expect(usage.resetStatus?.latestUsedAt(for: .fiveHour) == Date(timeIntervalSince1970: usedAtMs / 1000))
    }

    @Test func consommationNonConfirméeMalgréEnvoi() async throws {
        // Le `use` est accepté mais l'historique ne bouge pas : erreur douce, jauges quand même relues.
        let (usage, server) = try await readyUsage(status: { _ in resetStatusJSON() })
        await server.on("usage-stats.useCodingPlanReset") { _ in .object(["used": .bool(true)]) }
        await usage.useReset(.week)
        #expect(usage.resetNotice == nil)
        #expect(usage.resetError == "Réinitialisation envoyée, mais non confirmée par le fournisseur. Actualise.")
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus").count >= 6)   // 1 lecture + 5 confirmations
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 2)
    }

    @Test func refusDuFournisseur() async throws {
        let (usage, server) = try await readyUsage()
        await server.on("usage-stats.useCodingPlanReset") { _ in
            throw RPCTestError(message: "coding_plan_reset_api_error:3305 (x-request-id:abc)")
        }
        await usage.useReset(.fiveHour)
        #expect(usage.resetError == "Le fournisseur a refusé la réinitialisation (code 3305).")
        #expect(usage.resetNotice == nil)
        #expect(usage.isResetting == false)
        // L'échec relit le statut (l'envoi a pu partir) mais pas les jauges.
        #expect(await server.calls(to: "usage-stats.getCodingPlanResetStatus").count == 2)
        #expect(await server.calls(to: "usage-stats.getEntitlementSnapshot").count == 1)
    }

    @Test func gardeFousDeLaConsommation() async throws {
        let (usage, server) = try await readyUsage()
        await usage.useReset(.fiveHour)
        #expect(await server.calls(to: "usage-stats.useCodingPlanReset").count == 1)
        // Sans opportunité du type : refus silencieux, aucun envoi.
        let empty = try await readyUsage(status: { _ in resetStatusJSON(fiveHour: 0, week: 2) })
        await empty.0.useReset(.fiveHour)
        #expect(await empty.1.calls(to: "usage-stats.useCodingPlanReset").isEmpty)
        // Sans statut lu du tout : refus silencieux.
        let none = makeUsage(ServerQueue([]))
        await none.useReset(.fiveHour)
        #expect(none.resetError == nil)
    }

    @Test func hoteInjoignablePendantLAction() async throws {
        let (usage, server) = try await readyUsage()
        await server.transport.finish()                                  // la connexion tombe avant l'action
        await usage.useReset(.fiveHour)
        #expect(usage.resetError != nil)
        #expect(usage.resetNotice == nil)
        #expect(usage.isResetting == false)
        #expect(await server.calls(to: "usage-stats.useCodingPlanReset").isEmpty)
    }
}

/// Erreur distante telle que le faux serveur la renvoie (message de l'hôte).
private struct RPCTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
