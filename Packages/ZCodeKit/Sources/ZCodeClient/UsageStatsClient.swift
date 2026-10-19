import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Canal `usage-stats` de l'hôte (service global, sans espace de travail) : quotas et abonnement du Coding Plan d'un
/// fournisseur par compte. L'hôte interroge Z.ai / BigModel lui-même : l'app ne voit jamais de clé.
public struct UsageStatsClient: Sendable {
    public static let channel = "usage-stats"
    public let client: ChannelClient

    public init(client: ChannelClient) {
        self.client = client
    }

    /// `getEntitlementSnapshot` pour ce seul fournisseur : `requirePreferredProvider` interdit le repli sur un autre
    /// compte et `allowEnvApiKey: false` celui sur une clé d'environnement de l'hôte ; `accountAccess` est celui lu dans
    /// `model-selection` (sans lui, l'hôte répond `not_configured`). Abonnement toujours demandé (dates de
    /// renouvellement).
    public func entitlement(providerId: String, accountAccess: ProviderAccountAccess) async throws -> UsageEntitlementSnapshot {
        let value = try await client.call(Self.channel, "getEntitlementSnapshot", .array([RPCValue(.object([
            "includeSubscription": .bool(true), "preferredProviderId": .string(providerId),
            "accountAccess": accountAccess.json, "requirePreferredProvider": .bool(true), "allowEnvApiKey": .bool(false),
        ]))]))
        do {
            return try UsageEntitlementSnapshot(json: value.jsonValue ?? .null)
        } catch {
            throw AgentV4Error.malformedResponse(method: "usage-stats.getEntitlementSnapshot", detail: "\(error)")
        }
    }

    // MARK: - Réinitialisations du Coding Plan

    /// Objet `scope` commun aux quatre appels de réinitialisation.
    private static func scope(_ providerId: String, _ accountAccess: ProviderAccountAccess) -> RPCValue {
        RPCValue(.object(["preferredProviderId": .string(providerId), "accountAccess": accountAccess.json]))
    }

    /// `getCodingPlanResetStatus` : réinitialisations accordées et non consommées, et dernière consommée par type.
    /// Ne liste que les opportunités déjà accordées : voir `requestResetOpportunity`.
    public func resetStatus(providerId: String, accountAccess: ProviderAccountAccess) async throws -> CodingPlanResetStatus {
        let value = try await client.call(Self.channel, "getCodingPlanResetStatus", .array([Self.scope(providerId, accountAccess)]))
        do {
            return try CodingPlanResetStatus(json: value.jsonValue ?? .null)
        } catch {
            throw AgentV4Error.malformedResponse(method: "usage-stats.getCodingPlanResetStatus", detail: "\(error)")
        }
    }

    /// `requestCodingPlanResetOpportunity` : demande au fournisseur d'évaluer l'éligibilité et d'accorder une
    /// opportunité. Un refus (`granted == false`, avec `nextTryAt`) n'est pas une erreur. L'hôte rejette les clés vides
    /// ou de plus de 64 caractères.
    public func requestResetOpportunity(providerId: String, accountAccess: ProviderAccountAccess,
                                        idempotencyKey: String) async throws -> CodingPlanResetOpportunityResult {
        let value = try await client.call(Self.channel, "requestCodingPlanResetOpportunity", .array([RPCValue(.object([
            "preferredProviderId": .string(providerId), "accountAccess": accountAccess.json,
            "idempotencyKey": .string(idempotencyKey),
        ]))]))
        return CodingPlanResetOpportunityResult(json: value.jsonValue ?? .null)
    }

    /// `useCodingPlanReset` : consomme une opportunité du type donné. La clé d'idempotence borne la double
    /// consommation quand le fournisseur reçoit le même `use` deux fois ; chaque action de l'app porte la sienne.
    public func useReset(providerId: String, accountAccess: ProviderAccountAccess, idempotencyKey: String,
                         type: CodingPlanResetType) async throws {
        let value = try await client.call(Self.channel, "useCodingPlanReset", .array([RPCValue(.object([
            "preferredProviderId": .string(providerId), "accountAccess": accountAccess.json,
            "idempotencyKey": .string(idempotencyKey), "resetType": .string(type.rawValue),
        ]))]))
        guard value.jsonValue?["used"]?.boolValue == true else {
            throw AgentV4Error.malformedResponse(method: "usage-stats.useCodingPlanReset", detail: "used absent")
        }
    }

    /// `markCodingPlanResetHistoryRead` : curseur de lecture partagé par l'utilisateur (le serveur l'applique à tous
    /// ses scopes) ; sans effet tant que l'hôte n'a pas consommé de réinitialisation.
    public func markResetHistoryRead(providerId: String, accountAccess: ProviderAccountAccess) async throws {
        _ = try await client.call(Self.channel, "markCodingPlanResetHistoryRead", .array([Self.scope(providerId, accountAccess)]))
    }
}
