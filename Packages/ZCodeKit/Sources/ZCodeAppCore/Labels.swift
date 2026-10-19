import Foundation
import ZCodeV4

extension SessionPhase {
    public var label: String {
        switch self {
        case .draft: "Brouillon"
        case .prewarming: "Démarrage"
        case .running: "En cours"
        case .completedSuccess: "Terminée"
        case .completedInterrupted: "Interrompue"
        case .error: "Erreur"
        default: rawValue
        }
    }

    /// Un tour est en cours sur l'hôte.
    public var isBusy: Bool { self == .running || self == .prewarming }
}

extension SessionSummary {
    /// Approbations et questions en attente de réponse.
    public var pendingCount: Int {
        if let counts = pendingInteractionSummary {
            return counts.permissionCount + counts.userInputCount
        }
        return pendingInteraction == nil ? 0 : 1
    }

    public var lastActivityDate: Date { Date(timeIntervalSince1970: lastActivityAt / 1000) }
}

extension GitChangeKind {
    public var label: String {
        switch self {
        case .modified: "Modifié"
        case .added: "Ajouté"
        case .deleted: "Supprimé"
        case .renamed: "Renommé"
        default: rawValue
        }
    }
}
