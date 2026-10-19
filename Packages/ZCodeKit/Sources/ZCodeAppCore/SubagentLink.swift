import Foundation
import ZCodeV4
import ZCodeWire

/// Sous-agent porté par la carte de l'outil qui l'a lancé (lot 13D, `agentToolCall` du web).
public struct SubagentLink: Equatable, Sendable {
    public let title: String
    public let subagentType: String
    /// `running | success | failed | cancelled` ; inconnu gardé tel quel.
    public let status: String
    public let summaryText: String
    /// Présent ⇒ « Voir le fil » ouvre `conversation/<childSessionId>` en lecture seule.
    public let childSessionId: String?

    public var statusLabel: String {
        switch status {
        case "running": "En cours"
        case "success": "Terminé"
        case "failed": "Échec"
        case "cancelled": "Annulé"
        default: status
        }
    }

    /// Comme un outil réussi : pas de statut affiché sur la ligne compacte.
    public var isFinishedSuccess: Bool { status == "success" }

    init(tool row: ConversationRow, call: ToolCall, subagent: Subagent) {
        title = Self.title(raw: row.raw, input: call.input, subagentType: subagent.subagentType)
        subagentType = subagent.subagentType
        status = subagent.status
        summaryText = subagent.summaryText
        childSessionId = subagent.childSessionId
    }

    /// `getAgentPrimaryText` du web, sans le titre d'appel (absent des lignes v4) : surnom, description, type demandé.
    static func title(raw: [String: JSONValue], input: JSONValue?, subagentType: String) -> String {
        let candidates: [JSONValue?] = [
            raw["_meta"]?["zcode"]?["nickname"], raw["nickname"], input?["nickname"],
            input?["description"], input?["subagent_type"], input?["agent_type"], .string(subagentType),
        ]
        for candidate in candidates {
            if let text = candidate?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return "Sous-agent"
    }

    /// Outils qui lancent un sous-agent (`SUBAGENT_TOOL_NAMES` du web).
    static let toolNames: Set<String> = ["Agent", "Task", "subagent"]
}

/// Libellés des sous-agents en cours (puce et liste, lot 13D).
public enum SubagentLabels {
    public static func runningCount(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 sous-agent"
        default: "\(count) sous-agents"
        }
    }

    public static func runningStatus(_ status: String) -> String {
        switch status {
        case "running": "en cours"
        case "waiting": "en attente"
        case "blocked": "bloqué"
        default: status
        }
    }
}
