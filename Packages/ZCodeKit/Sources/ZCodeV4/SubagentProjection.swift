import Foundation
import ZCodeWire

/// Sous-agent en cours d'une session (`snapshot.subagents.running[]`, `runningSubagentSummarySchema`).
public struct RunningSubagent: Equatable, Sendable, Identifiable {
    public let childSessionId: String
    public let agentId: String?
    public let toolCallId: String?
    public let subagentType: String
    public let title: String
    public let summary: String?
    /// `running | waiting | blocked` ; valeur inconnue gardée telle quelle.
    public let status: String
    public let startedAt: Double?

    public var id: String { childSessionId }

    /// `nil` sans `childSessionId` (rien à ouvrir) ; les autres champs sont tolérants.
    init?(json: JSONValue) {
        guard let child = json["childSessionId"]?.stringValue, !child.isEmpty else { return nil }
        childSessionId = child
        agentId = json["agentId"]?.stringValue
        toolCallId = json["toolCallId"]?.stringValue
        subagentType = json["subagentType"]?.stringValue ?? ""
        title = json["title"]?.stringValue ?? ""
        summary = json["summary"]?.stringValue
        status = json["status"]?.stringValue ?? ""
        startedAt = json["startedAt"]?.numberValue
    }
}

extension ConversationSnapshot {
    /// Sous-agents en cours (mis à jour par `state.updated`, qui remplace `subagents` en entier).
    public var runningSubagents: [RunningSubagent] {
        (state["subagents"]?["running"]?.arrayValue ?? []).compactMap(RunningSubagent.init(json:))
    }
}
