import Foundation
import ZCodeRPC
import ZCodeV4

/// Libellés français de l'écran d'utilisation du Coding Plan (les nombres et dates sont formatés par les vues, dans la
/// locale de l'appareil).
public enum UsageLabels {
    public static func title(_ window: UsageWindow) -> String {
        switch window {
        case .fiveHours: "Fenêtre de 5 heures"
        case .weekly: "Semaine"
        case .monthlyTools: "Appels d'outils du mois"
        case .mcp: "MCP officiel ZCode"
        case .other: "Autre limite"
        }
    }

    /// Fenêtre inconnue : ce que le fournisseur en dit (`type`, `number` × `unit`), pour ne rien cacher.
    public static func detail(_ limit: UsageQuotaLimit) -> String? {
        guard limit.window == .other else { return nil }
        var parts = [limit.type.rawValue]
        if let number = limit.number, let unit = limit.unit { parts.append("\(number) × unité \(unit)") }
        return parts.joined(separator: ", ")
    }

    /// Unité des montants d'une limite : crédits d'une fenêtre, sinon appels (outils, MCP).
    public static func unit(_ limit: UsageQuotaLimit) -> String {
        limit.type.isCredits ? "crédits" : "appels"
    }

    /// Les fenêtres courtes montrent l'heure de réinitialisation ; semaine, mois et MCP (minuit) seulement la date.
    public static func showsResetTime(_ window: UsageWindow) -> Bool {
        window == .fiveHours || window == .other
    }

    public static func unavailable(_ reason: UsageUnavailableReason?) -> String {
        switch reason {
        case .notConfigured?: "Aucun compte Coding Plan connecté sur l'hôte pour ce fournisseur."
        case .notAuthenticated?: "Connecte-toi au Coding Plan dans ZCode sur l'hôte pour voir l'utilisation."
        case .noPlan?: "Aucun Coding Plan actif sur ce compte."
        default: "Données d'utilisation indisponibles pour le moment."
        }
    }

    /// Cycle de facturation tel que le fournisseur le nomme ; inconnu tel quel.
    public static func billingCycle(_ cycle: String?) -> String? {
        switch cycle?.lowercased() {
        case nil, ""?: nil
        case "annually"?, "yearly"?: "Annuel"
        case "monthly"?: "Mensuel"
        case "quarterly"?: "Trimestriel"
        case let other?: other
        }
    }

    /// Nom du plan : commercial (`context.displayName`), sinon reconstruit du niveau comme l'hôte (« GLM Coding Max »),
    /// sinon le fournisseur.
    public static func planTitle(_ snapshot: UsageEntitlementSnapshot) -> String? {
        if let planName = snapshot.planName { return planName }
        if let level = snapshot.level { return "GLM Coding " + level.prefix(1).uppercased() + level.dropFirst().lowercased() }
        return snapshot.providerName
    }

    /// Erreur d'une lecture (`usage-stats`) : messages connus de l'hôte traduits, le reste tel quel.
    public static func failure(_ error: any Error) -> String {
        guard case RPCError.remote(let remote) = error else { return ConnectionFailure(error).message }
        let text = remote.message
        if text.contains("no_bigmodel_api_key") { return "Ce fournisseur n'est pas un Coding Plan Z.ai / BigModel." }
        if text.contains("entitlement refresh failed") {
            return "Le fournisseur n'a pas répondu à l'hôte : abonnement illisible pour le moment. Réessaie."
        }
        if text.contains("timeout") { return "Le fournisseur a mis trop de temps à répondre à l'hôte. Réessaie." }
        return text.isEmpty ? "Erreur du serveur ZCode." : text
    }

    // MARK: - Réinitialisations du Coding Plan

    /// Titre d'une ligne de réinitialisation : celui de la fenêtre qu'elle remet à neuf.
    public static func resetTitle(_ type: CodingPlanResetType) -> String {
        switch type {
        case .fiveHour: title(.fiveHours)
        case .week: title(.weekly)
        }
    }

    /// Succès d'une consommation.
    public static func resetDone(_ type: CodingPlanResetType) -> String {
        switch type {
        case .fiveHour: "Fenêtre de 5 heures réinitialisée."
        case .week: "Quota de la semaine réinitialisé."
        }
    }

    /// « N réinitialisation(s) disponible(s) ».
    public static func resetOpportunities(_ count: Int) -> String {
        "\(count) réinitialisation\(count > 1 ? "s" : "") disponible\(count > 1 ? "s" : "")"
    }

    /// Titre du dialogue de confirmation avant consommation.
    public static func resetConfirmationTitle(_ type: CodingPlanResetType) -> String {
        switch type {
        case .fiveHour: "Réinitialiser la fenêtre de 5 heures ?"
        case .week: "Réinitialiser le quota de la semaine ?"
        }
    }

    /// Corps du dialogue : ce que la consommation enlève et ce qu'elle rend.
    public static func resetConfirmationMessage(_ type: CodingPlanResetType, count: Int) -> String {
        let consumed = count > 1 ? "Il restera \(count - 1) réinitialisation\(count - 1 > 1 ? "s" : "") de ce type."
            : "C'était la dernière réinitialisation de ce type."
        let restored: String
        switch type {
        case .fiveHour: restored = "Le quota de la fenêtre de 5 heures repartira plein."
        case .week: restored = "Le quota de la semaine repartira plein."
        }
        return "\(restored) \(consumed)"
    }

    /// Erreur d'une lecture ou d'une consommation de réinitialisation : messages connus de l'hôte traduits, le reste
    /// tel quel.
    public static func resetFailure(_ error: any Error) -> String {
        guard case RPCError.remote(let remote) = error else { return ConnectionFailure(error).message }
        let text = remote.message
        if text.contains("no_bigmodel_api_key") { return "Ce fournisseur n'est pas un Coding Plan Z.ai / BigModel." }
        if text.contains("coding_plan_reset_opportunity_throttled") {
            return "Le fournisseur limite les demandes de réinitialisation pour l'instant. Réessaie dans un moment."
        }
        if text.contains("coding_plan_reset_account_access_required") {
            return "Aucun compte Coding Plan connecté sur l'hôte pour ce fournisseur."
        }
        if text.contains("coding_plan_reset_zcode_jwt_required") || text.contains("coding_plan_reset_maas_jwt_required") {
            return "Reconnecte le Coding Plan dans ZCode sur l'hôte, puis réessaie."
        }
        // `coding_plan_reset_api_error:<code> (x-request-id:…)` : le code seul, sans l'identifiant de requête.
        if let code = text.prefix(while: { $0 != " " }).afterPrefix("coding_plan_reset_api_error:"), !code.isEmpty {
            return "Le fournisseur a refusé la réinitialisation (code \(code))."
        }
        if text.contains("timeout") { return "Le fournisseur a mis trop de temps à répondre à l'hôte. Réessaie." }
        return text.isEmpty ? "Erreur du serveur ZCode." : text
    }
}

private extension Substring {
    /// `nil` sauf si la tranche commence par ce préfixe ; alors ce qui suit le préfixe.
    func afterPrefix(_ prefix: String) -> Substring? {
        starts(with: prefix) ? dropFirst(prefix.count) : nil
    }
}

/// Rappel du quota dans le composeur : part restante des fenêtres de 5 heures et de la semaine.
public struct ComposerQuota: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case normal
        /// Moins de 20 % restants.
        case low
        /// Moins de 5 % restants.
        case critical
    }

    /// Un anneau : une fenêtre et sa part restante.
    public struct Ring: Equatable, Sendable {
        /// Part restante arrondie (0–100).
        public let percent: Int
        /// `percent` / 100, borné à [0, 1].
        public let fraction: Double
        /// Niveau d'après la valeur arrondie.
        public let level: Level

        init(remaining: Double) {
            percent = Int(remaining.rounded())
            fraction = min(1, max(0, Double(percent) / 100))
            level = percent < 5 ? .critical : (percent < 20 ? .low : .normal)
        }
    }

    public let fiveHours: Ring
    /// `nil` si le fournisseur ne renvoie pas de fenêtre hebdomadaire.
    public let weekly: Ring?
    /// « 61 % » (restant des 5 h).
    public let text: String
    public let accessibilityLabel: String

    /// Compatibilité : valeurs de la fenêtre de 5 heures.
    public var percent: Int { fiveHours.percent }
    public var level: Level { fiveHours.level }
}

extension UsageLabels {
    /// `nil` : rien à montrer (pas encore lu, pas de fenêtre de 5 h, solde masqué par le fournisseur).
    public static func composerQuota(_ snapshot: UsageEntitlementSnapshot?) -> ComposerQuota? {
        guard let snapshot, !snapshot.balanceHidden,
              let remaining = snapshot.limit(for: .fiveHours)?.remainingPercentage else { return nil }
        let fiveHours = ComposerQuota.Ring(remaining: remaining)
        let weekly = snapshot.limit(for: .weekly)?.remainingPercentage.map(ComposerQuota.Ring.init(remaining:))
        let fiveHoursLabel = "Quota restant : \(fiveHours.percent) % sur 5 heures"
        let label = weekly.map { "\(fiveHoursLabel), \($0.percent) % sur la semaine" } ?? fiveHoursLabel
        return ComposerQuota(fiveHours: fiveHours, weekly: weekly, text: "\(fiveHours.percent) %", accessibilityLabel: label)
    }
}
