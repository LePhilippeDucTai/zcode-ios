import Foundation
import ZCodeWire

public struct PendingInteractionSummary: Codable, Equatable, Sendable {
    public let interactionId: String
    public let kind: InteractionKind
    public let toolName: String?
}

public struct PendingInteractionCounts: Codable, Equatable, Sendable {
    public let permissionCount: Int
    public let userInputCount: Int
}

/// Résumé d'une session pour la liste (`sessions-index.ts`).
public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let workspaceId: String
    public let parentSessionId: String?
    public let title: String
    public let titleSource: String?
    public let phase: SessionPhase
    public let sessionEnded: Bool?
    public let hasBackgroundWork: Bool?
    public let pendingInteraction: PendingInteractionSummary?
    public let pendingInteractionSummary: PendingInteractionCounts?
    public let goalStatus: GoalStatus?
    public let lastActivityAt: Double
    public let lastAssistantPreview: String?
    public let createdAt: Double?
    public let workflowActivity: WorkflowActivitySummary?

    public var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId, workspaceId, parentSessionId, title, titleSource, phase, sessionEnded, hasBackgroundWork
        case pendingInteraction, pendingInteractionSummary, goalStatus, lastActivityAt, lastAssistantPreview
        case createdAt, workflowActivity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        title = try container.decode(String.self, forKey: .title)
        titleSource = try container.decodeIfPresent(String.self, forKey: .titleSource)
        phase = try container.decode(SessionPhase.self, forKey: .phase)
        sessionEnded = try container.decodeIfPresent(Bool.self, forKey: .sessionEnded)
        hasBackgroundWork = try container.decodeIfPresent(Bool.self, forKey: .hasBackgroundWork)
        pendingInteraction = try container.decodeIfPresent(PendingInteractionSummary.self, forKey: .pendingInteraction)
        pendingInteractionSummary = try container.decodeIfPresent(
            PendingInteractionCounts.self, forKey: .pendingInteractionSummary)
        goalStatus = try container.decodeIfPresent(GoalStatus.self, forKey: .goalStatus)
        lastActivityAt = try container.decode(Double.self, forKey: .lastActivityAt)
        lastAssistantPreview = try container.decodeIfPresent(String.self, forKey: .lastAssistantPreview)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        // Tolérant : une activité illisible ne fait pas perdre le résumé de la session.
        workflowActivity = try? container.decodeIfPresent(WorkflowActivitySummary.self, forKey: .workflowActivity)
    }
}

public enum SessionsIndexDelta: Equatable, Sendable {
    case upserted(SessionSummary)
    case removed(sessionId: String)
    /// Opération inconnue ou résumé mal formé : ignoré.
    case unknown(op: String, raw: JSONValue)

    public init(json: JSONValue) {
        let op = json["op"]?.stringValue ?? ""
        switch op {
        case "session.upserted":
            if let session = json["session"], let summary = try? V4JSON.decode(SessionSummary.self, from: session) {
                self = .upserted(summary)
                return
            }
        case "session.removed":
            if let sessionId = json["sessionId"]?.stringValue {
                self = .removed(sessionId: sessionId)
                return
            }
        default:
            break
        }
        self = .unknown(op: op, raw: json)
    }
}

/// Liste des sessions d'un espace de travail, tenue à jour par les deltas.
public struct SessionsIndex: Equatable, Sendable {
    public let workspaceId: String
    public let logEpoch: String
    /// Ordre du serveur ; `byRecentActivity` pour l'affichage.
    public private(set) var sessions: [SessionSummary]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let workspaceId = json["workspaceId"]?.stringValue else { throw .missingField("workspaceId") }
        guard let logEpoch = json["logEpoch"]?.stringValue else { throw .missingField("logEpoch") }
        guard let sessions = json["sessions"]?.arrayValue else { throw .missingField("sessions") }
        self.workspaceId = workspaceId
        self.logEpoch = logEpoch
        // Un résumé mal formé est ignoré ; les autres restent visibles.
        self.sessions = sessions.compactMap { try? V4JSON.decode(SessionSummary.self, from: $0) }
    }

    public var byRecentActivity: [SessionSummary] {
        sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func session(id: String) -> SessionSummary? {
        sessions.first { $0.sessionId == id }
    }

    /// Copie hors ligne (lot 13E-1) : JSON qu'accepte `init(json:)`, sans les sessions `hidden` (archivées).
    public func offlineJSON(excluding hidden: Set<String>) throws -> JSONValue {
        .object([
            "workspaceId": .string(workspaceId),
            "logEpoch": .string(logEpoch),
            "sessions": .array(try sessions.filter { !hidden.contains($0.sessionId) }.map { try V4JSON.encode($0) }),
        ])
    }

    public mutating func apply(_ deltas: [SessionsIndexDelta]) {
        for delta in deltas {
            apply(delta)
        }
    }

    public mutating func apply(_ delta: SessionsIndexDelta) {
        switch delta {
        case .upserted(let summary):
            if let index = sessions.firstIndex(where: { $0.sessionId == summary.sessionId }) {
                sessions[index] = summary
            } else {
                sessions.append(summary)
            }
        case .removed(let sessionId):
            sessions.removeAll { $0.sessionId == sessionId }
        case .unknown:
            break
        }
    }
}
