import Foundation
import ZCodeWire

/// Type d'une limite de quota (`UsageQuotaLimit.type` de ZCode). Z.ai répond `CREDIT_LIMIT` et BigModel `TOKENS_LIMIT`
/// pour la même chose (crédits d'une fenêtre) ; `TIME_LIMIT` compte les appels d'outils ; `MCP_USAGE_LIMIT` est
/// synthétisé par l'hôte pour le MCP officiel de ZCode.
public struct UsageLimitType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let creditLimit = UsageLimitType(rawValue: "CREDIT_LIMIT")
    public static let tokensLimit = UsageLimitType(rawValue: "TOKENS_LIMIT")
    public static let timeLimit = UsageLimitType(rawValue: "TIME_LIMIT")
    public static let mcpUsageLimit = UsageLimitType(rawValue: "MCP_USAGE_LIMIT")

    /// Crédits (ou jetons) d'une fenêtre glissante, quel que soit le nom que lui donne le fournisseur.
    public var isCredits: Bool { self == .creditLimit || self == .tokensLimit }
}

/// Fenêtre d'une limite, déduite comme l'interface web de ZCode de `type`, `unit` et `number` (`unit` 3 = heures,
/// 5 = mois, 6 = semaines).
public enum UsageWindow: Equatable, Hashable, Sendable {
    /// Crédits sur 5 heures glissantes (`unit` 3, `number` 5).
    case fiveHours
    /// Crédits de la semaine (`unit` 6).
    case weekly
    /// Appels d'outils du mois (`TIME_LIMIT`, `unit` 5, `number` 1).
    case monthlyTools
    /// MCP officiel de ZCode (`MCP_USAGE_LIMIT`, réinitialisé chaque jour).
    case mcp
    case other

    /// Ordre d'affichage : du plus court au plus long, le MCP en dernier.
    public static let displayOrder: [UsageWindow] = [.fiveHours, .weekly, .monthlyTools, .other, .mcp]
}

/// Une limite du Coding Plan (`UsageQuotaLimit` de ZCode), transmise telle que le fournisseur la renvoie. Les noms des
/// champs du fournisseur trompent : `usage` est le **plafond** de la fenêtre (sauf l'agrégat du MCP officiel, où il vaut 0
/// et où le total se reconstruit par « consommé + restant »), `currentValue` le consommé et `percentage` la part consommée
/// (l'interface web l'inverse pour afficher le restant).
public struct UsageQuotaLimit: Equatable, Sendable {
    public let type: UsageLimitType
    public let unit: Int?
    public let number: Int?
    /// Plafond de la fenêtre (`usage`).
    public let total: Int?
    /// Consommé (`currentValue`).
    public let used: Int?
    public let remaining: Int?
    /// Part consommée, de 0 à 100 (`percentage`).
    public let usedPercentage: Double?
    public let nextReset: Date?

    public init(type: UsageLimitType, unit: Int? = nil, number: Int? = nil, total: Int? = nil, used: Int? = nil,
                remaining: Int? = nil, usedPercentage: Double? = nil, nextReset: Date? = nil) {
        self.type = type
        self.unit = unit
        self.number = number
        self.total = total
        self.used = used
        self.remaining = remaining
        self.usedPercentage = usedPercentage
        self.nextReset = nextReset
    }

    /// `nil` sans `type` : une limite sans type n'est pas affichable (l'hôte les écarte aussi).
    public init?(json: JSONValue?) {
        guard let json, let type = json["type"]?.stringValue, !type.isEmpty else { return nil }
        let used = V4JSON.integer(json["currentValue"])
        let remaining = V4JSON.integer(json["remaining"])
        // Les fenêtres de crédits annoncent leur plafond dans `usage` ; l'agrégat du MCP officiel laisse ce champ à 0 et
        // n'exprime le total que par « consommé + restant ».
        let reportedTotal = V4JSON.integer(json["usage"]) ?? 0
        let parts = [used, remaining].compactMap { $0 }
        let total = reportedTotal > 0 ? reportedTotal : (parts.isEmpty ? nil : parts.reduce(0, +))
        self.init(type: UsageLimitType(rawValue: type), unit: V4JSON.integer(json["unit"]),
                  number: V4JSON.integer(json["number"]), total: total, used: used, remaining: remaining,
                  usedPercentage: json["percentage"]?.numberValue, nextReset: UsageDates.epochMilliseconds(json["nextResetTime"]))
    }

    public var window: UsageWindow {
        if type == .mcpUsageLimit { return .mcp }
        if type.isCredits {
            if unit == 3, number == 5 { return .fiveHours }
            if unit == 6 { return .weekly }
            return .other
        }
        if type == .timeLimit, unit == 5, number == 1 { return .monthlyTools }
        return .other
    }

    /// Part restante (0–100), `nil` sans pourcentage du fournisseur.
    public var remainingPercentage: Double? {
        guard let usedPercentage, usedPercentage.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercentage))
    }

    /// Part consommée de 0 à 1 pour une barre de progression ; calculée sur les montants à défaut de pourcentage.
    public var usedFraction: Double {
        if let usedPercentage, usedPercentage.isFinite { return min(1, max(0, usedPercentage / 100)) }
        if let used, let total, total > 0 { return min(1, max(0, Double(used) / Double(total))) }
        return 0
    }
}

/// Un abonnement en cours (`UsageEntitlementSubscriptionDetail`).
public struct UsageSubscriptionDetail: Equatable, Sendable {
    public let productId: String
    public let productName: String
    /// `annually`, `monthly`… tel que le fournisseur le dit.
    public let billingCycle: String?
    public let renewTime: Date?
    public let expireTime: Date?

    init?(json: JSONValue) {
        let name = json["productName"]?.stringValue ?? ""
        let id = json["productId"]?.stringValue ?? ""
        guard !name.isEmpty || !id.isEmpty else { return nil }
        productId = id
        productName = name.isEmpty ? id : name
        billingCycle = json["billingCycle"]?.stringValue
        renewTime = UsageDates.iso8601(json["renewTime"])
        expireTime = UsageDates.iso8601(json["expireTime"])
    }
}

/// Raison pour laquelle l'hôte ne renvoie aucun quota (`unavailableReason`).
public struct UsageUnavailableReason: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let notAuthenticated = UsageUnavailableReason(rawValue: "not_authenticated")
    /// Aucun compte Coding Plan connecté pour ce fournisseur sur l'hôte.
    public static let notConfigured = UsageUnavailableReason(rawValue: "not_configured")
    public static let noPlan = UsageUnavailableReason(rawValue: "no_plan")
    public static let unavailable = UsageUnavailableReason(rawValue: "unavailable")
}

/// Réponse de `usage-stats.getEntitlementSnapshot` (`UsageEntitlementSnapshot` de ZCode) : quotas et abonnement du
/// Coding Plan d'un fournisseur par compte. Lue champ par champ ; une réponse sans quota (`unavailableReason`) n'est pas
/// une erreur.
public struct UsageEntitlementSnapshot: Equatable, Sendable {
    public let generatedAt: Date?
    public let authenticated: Bool
    public let unavailableReason: UsageUnavailableReason?
    /// Nom commercial du plan (`context.displayName`, ex. « GLM Coding Max »).
    public let planName: String?
    public let providerId: String?
    public let providerName: String?
    /// Niveau du plan (`quota.level` : `lite`, `pro`, `max`…).
    public let level: String?
    /// Limites du fournisseur, dans son ordre.
    public let limits: [UsageQuotaLimit]
    /// Quota du MCP officiel de ZCode (`mcpQuota.aggregate`), à part des `limits` côté hôte.
    public let mcpLimit: UsageQuotaLimit?
    public let subscriptions: [UsageSubscriptionDetail]
    /// `remaining.isShow == false` : le fournisseur demande de ne pas afficher le solde.
    public let balanceHidden: Bool

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let object = json.objectValue else { throw .invalid("usage-stats.getEntitlementSnapshot") }
        generatedAt = UsageDates.epochMilliseconds(object["generatedAt"])
        authenticated = object["authenticated"]?.boolValue ?? false
        unavailableReason = object["unavailableReason"]?.stringValue.map(UsageUnavailableReason.init(rawValue:))
        planName = Self.nonEmpty(object["context"]?["displayName"])
        providerId = Self.nonEmpty(object["provider"]?["id"])
        providerName = Self.nonEmpty(object["provider"]?["name"])
        level = Self.nonEmpty(object["quota"]?["level"])
        limits = (object["quota"]?["limits"]?.arrayValue ?? []).compactMap(UsageQuotaLimit.init(json:))
        mcpLimit = UsageQuotaLimit(json: object["mcpQuota"]?["aggregate"])
        subscriptions = (object["subscription"]?["details"]?.arrayValue ?? []).compactMap(UsageSubscriptionDetail.init(json:))
        balanceHidden = object["remaining"]?["isShow"]?.boolValue == false
    }

    /// Première limite de cette fenêtre (le MCP vient de `mcpLimit`).
    public func limit(for window: UsageWindow) -> UsageQuotaLimit? {
        if window == .mcp { return mcpLimit }
        return limits.first { $0.window == window }
    }

    /// Toutes les limites affichables, dans l'ordre de `UsageWindow.displayOrder` (fenêtre inconnue : ordre du
    /// fournisseur), le MCP en dernier.
    public var displayedLimits: [UsageQuotaLimit] {
        var result: [UsageQuotaLimit] = []
        for window in UsageWindow.displayOrder where window != .mcp {
            result += limits.filter { $0.window == window }
        }
        if let mcpLimit { result.append(mcpLimit) }
        return result
    }

    /// Rien à montrer : ni limite, ni niveau de plan.
    public var isEmpty: Bool { limits.isEmpty && mcpLimit == nil && level == nil }

    private static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

/// Dates telles que le fournisseur les écrit : époques en millisecondes et chaînes ISO 8601 (avec ou sans fraction).
enum UsageDates {
    static func epochMilliseconds(_ value: JSONValue?) -> Date? {
        guard let milliseconds = value?.numberValue, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    static func iso8601(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
