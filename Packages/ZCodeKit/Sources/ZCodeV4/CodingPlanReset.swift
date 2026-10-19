import Foundation
import ZCodeWire

/// Type d'une réinitialisation de quota du Coding Plan (`CodingPlanResetType` de ZCode) : fenêtre de 5 heures ou
/// semaine. Réinitialiser la fenêtre de 5 heures ne touche pas au quota hebdomadaire, et inversement.
public enum CodingPlanResetType: String, Equatable, Sendable, CaseIterable {
    case fiveHour = "FIVE_HOUR"
    case week = "WEEK"
}

/// Une réinitialisation accordée et non consommée (`CodingPlanResetOpportunitySnapshot`) : elle expire à `expireAt`
/// si elle n'est pas utilisée.
public struct CodingPlanResetOpportunity: Equatable, Sendable {
    public let expireAt: Date

    public init(expireAt: Date) {
        self.expireAt = expireAt
    }

    /// Entrée tolérante : sans `expireAt` lisible, l'entrée est écartée.
    public init?(json: JSONValue) {
        guard let expireAt = UsageDates.epochMilliseconds(json["expireAt"]) else { return nil }
        self.init(expireAt: expireAt)
    }
}

/// Réponse de `usage-stats.getCodingPlanResetStatus` : réinitialisations accordées et non consommées par type, et
/// date de la dernière consommée. Le statut ne liste que les opportunités **déjà accordées** : l'éligibilité
/// n'est évaluée par le fournisseur qu'à l'appel de `requestCodingPlanResetOpportunity`.
public struct CodingPlanResetStatus: Equatable, Sendable {
    public let availableFiveHourResets: [CodingPlanResetOpportunity]
    public let availableWeekResets: [CodingPlanResetOpportunity]
    public let latestFiveHourResetUsedAt: Date?
    public let latestWeekResetUsedAt: Date?
    /// Le fournisseur a une consommation que l'utilisateur n'a pas encore vue (curseur partagé par tous les scopes).
    public let hasUnreadHistory: Bool

    public init(availableFiveHourResets: [CodingPlanResetOpportunity], availableWeekResets: [CodingPlanResetOpportunity],
                latestFiveHourResetUsedAt: Date? = nil, latestWeekResetUsedAt: Date? = nil,
                hasUnreadHistory: Bool = false) {
        self.availableFiveHourResets = availableFiveHourResets
        self.availableWeekResets = availableWeekResets
        self.latestFiveHourResetUsedAt = latestFiveHourResetUsedAt
        self.latestWeekResetUsedAt = latestWeekResetUsedAt
        self.hasUnreadHistory = hasUnreadHistory
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let object = json.objectValue else { throw .invalid("usage-stats.getCodingPlanResetStatus") }
        self.init(
            availableFiveHourResets: (object["availableFiveHourResets"]?.arrayValue ?? []).compactMap(CodingPlanResetOpportunity.init(json:)),
            availableWeekResets: (object["availableWeekResets"]?.arrayValue ?? []).compactMap(CodingPlanResetOpportunity.init(json:)),
            latestFiveHourResetUsedAt: UsageDates.epochMilliseconds(object["latestFiveHourResetHistory"]?["usedAt"]),
            latestWeekResetUsedAt: UsageDates.epochMilliseconds(object["latestWeekResetHistory"]?["usedAt"]),
            hasUnreadHistory: object["hasUnreadHistory"]?.boolValue ?? false
        )
    }

    public func opportunities(for type: CodingPlanResetType) -> [CodingPlanResetOpportunity] {
        type == .week ? availableWeekResets : availableFiveHourResets
    }

    public func latestUsedAt(for type: CodingPlanResetType) -> Date? {
        type == .week ? latestWeekResetUsedAt : latestFiveHourResetUsedAt
    }

    /// Rien de consommable, pour aucun des deux types.
    public var isEmpty: Bool { availableFiveHourResets.isEmpty && availableWeekResets.isEmpty }
}

/// Réponse de `usage-stats.requestCodingPlanResetOpportunity` : un refus (`granted == false`) n'est pas une erreur —
/// le fournisseur retente plus tôt que `nextTryAt` (il limite les demandes, surtout quand une opportunité non
/// consommée est déjà détenue).
public struct CodingPlanResetOpportunityResult: Equatable, Sendable {
    public let granted: Bool
    public let nextTryAt: Date?

    public init(granted: Bool, nextTryAt: Date? = nil) {
        self.granted = granted
        self.nextTryAt = nextTryAt
    }

    public init(json: JSONValue) {
        self.init(granted: json["granted"]?.boolValue == true,
                  nextTryAt: UsageDates.epochMilliseconds(json["nextTryAt"]))
    }
}
