import Foundation
import ZCodeV4

/// Session d'un hôte qui attend une réponse ou dont un tour est en cours (section « Sessions en cours » de la fiche).
public struct ActiveSession: Equatable, Sendable, Identifiable {
    public let workspace: String
    public let summary: SessionSummary
    public var id: String { summary.sessionId }
    /// Attend une réponse (autorisation ou question) : règle de « En attente de vous ».
    public var waiting: Bool { summary.pendingCount > 0 }
    /// Nom du projet (dernier composant du chemin).
    public var projectName: String { URL(filePath: workspace).lastPathComponent }
}

/// Liste d'un projet telle que la fiche de l'hôte la voit.
public struct ActiveSessionsSource: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Index vivant reçu.
        case live
        /// Rien encore : premier chargement en cours.
        case loading
        /// Échec, ou copie hors ligne (état figé) : ignorée.
        case unavailable
    }

    public let workspace: String
    public let status: Status
    /// Sessions visibles (archivées exclues), sans brouillon local.
    public let sessions: [SessionSummary]

    public init(workspace: String, status: Status, sessions: [SessionSummary]) {
        self.workspace = workspace
        self.status = status
        self.sessions = sessions
    }
}

/// Clé de la tâche qui démarre les listes de la fiche (`.task(id:)` de `HostView`) : elle change avec les projets et à
/// chaque connexion établie (« Réessayer » ou reconnexion automatique), pour relancer les listes en échec.
public struct ActiveSessionsWatchKey: Hashable, Sendable {
    public let workspaces: [String]
    public let connected: Bool
}

public enum ActiveSessionsState: Equatable, Sendable {
    case loading
    case empty
    case entries(shown: [ActiveSession], hiddenCount: Int)
}

/// Règles de la section « Sessions en cours » (lot 13J).
public enum ActiveSessions {
    /// Lignes affichées au plus : la liste de la fiche est paresseuse, les projets doivent rester atteignables.
    public static let limit = 5

    public static func state(from sources: [ActiveSessionsSource], limit: Int = limit) -> ActiveSessionsState {
        var seen = Set<String>()
        var active: [ActiveSession] = []
        for source in sources where source.status == .live {
            for summary in source.sessions where summary.pendingCount > 0 || summary.phase.isBusy {
                guard seen.insert(summary.sessionId).inserted else { continue }
                active.append(ActiveSession(workspace: source.workspace, summary: summary))
            }
        }
        if active.isEmpty {
            return sources.contains { $0.status == .loading } ? .loading : .empty
        }
        let sorted = active.sorted { lhs, rhs in
            if lhs.waiting != rhs.waiting { return lhs.waiting }
            if lhs.summary.lastActivityAt != rhs.summary.lastActivityAt {
                return lhs.summary.lastActivityAt > rhs.summary.lastActivityAt
            }
            return lhs.id < rhs.id                              // ordre stable à activité égale
        }
        return .entries(shown: Array(sorted.prefix(limit)), hiddenCount: max(0, sorted.count - limit))
    }

    public static func hiddenLabel(_ count: Int) -> String {
        count == 1 ? "et 1 autre session en cours" : "et \(count) autres sessions en cours"
    }
}
