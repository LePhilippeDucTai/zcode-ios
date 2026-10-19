import Foundation
import ZCodeWire

public struct BackgroundWorkStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let running = BackgroundWorkStatus(rawValue: "running")
    public static let resultPending = BackgroundWorkStatus(rawValue: "resultPending")
    public static let failed = BackgroundWorkStatus(rawValue: "failed")
    public static let cancelled = BackgroundWorkStatus(rawValue: "cancelled")
}

/// Travail d'arrière-plan de la session (`backgroundWorks` du snapshot) ; un run de workflow en est un (`kind == "workflow"`).
public struct BackgroundWork: Decodable, Equatable, Sendable {
    public let workId: String
    public let kind: String
    public let title: String?
    public let status: BackgroundWorkStatus
    public let startedAt: Double?
    public let endedAt: Double?
    public let cancellable: Bool?
    public let anchorRowId: Int?
    public let childSessionId: String?
}

public struct WorkflowRunStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pending = WorkflowRunStatus(rawValue: "pending")
    public static let running = WorkflowRunStatus(rawValue: "running")
    public static let completed = WorkflowRunStatus(rawValue: "completed")
    public static let errored = WorkflowRunStatus(rawValue: "errored")
    public static let stopped = WorkflowRunStatus(rawValue: "stopped")
}

public struct WorkflowActorStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let waiting = WorkflowActorStatus(rawValue: "waiting")
    public static let running = WorkflowActorStatus(rawValue: "running")
    public static let completed = WorkflowActorStatus(rawValue: "completed")
}

public struct WorkflowActor: Decodable, Equatable, Sendable {
    public let siteId: String?
    public let ordinal: Int?
    public let name: String?
    public let sessionId: String?
    public let status: WorkflowActorStatus
    public let phaseName: String?
}

public struct WorkflowQuestion: Decodable, Equatable, Sendable {
    public let qid: String
    public let actorName: String?
    public let question: String
}

/// Run de workflow tel que le snapshot le porte (`workflowRuns.runs[]`).
public struct WorkflowRun: Equatable, Sendable, Identifiable {
    public let runId: String
    public let toolCallId: String?
    public let status: WorkflowRunStatus
    public let stopReason: String?
    public let spentTokens: Int?
    public let error: String?
    /// Jamais produit par l'hôte 3.15.1 ; gardé au cas où une version l'ajouterait.
    public let resultPreview: String?
    public let actors: [WorkflowActor]
    public let phaseNames: [String]
    public let currentPhase: String?
    public let pendingQuestions: [WorkflowQuestion]

    public var id: String { runId }

    /// Tolérant : `nil` sans `runId`, chaque autre champ illisible prend sa valeur vide.
    public init?(json: JSONValue) {
        guard let runId = json["runId"]?.stringValue else { return nil }
        self.runId = runId
        toolCallId = json["toolCallId"]?.stringValue
        status = WorkflowRunStatus(rawValue: json["status"]?.stringValue ?? "")
        stopReason = json["stopReason"]?.stringValue
        spentTokens = V4JSON.integer(json["usage"]?["spentTokens"])
        // Texte en 3.15.1 d'après la fiche ; un objet `{message}` est aussi accepté.
        error = json["error"]?.stringValue ?? json["error"]?["message"]?.stringValue
        resultPreview = json["resultPreview"]?.stringValue
        actors = (json["actors"]?.arrayValue ?? []).compactMap { try? V4JSON.decode(WorkflowActor.self, from: $0) }
        if let names = json["phaseNames"]?.arrayValue {
            phaseNames = names.compactMap(\.stringValue)
        } else {
            phaseNames = (json["phases"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        }
        currentPhase = json["currentPhase"]?.stringValue
        pendingQuestions = (json["pendingQuestions"]?.arrayValue ?? []).compactMap {
            try? V4JSON.decode(WorkflowQuestion.self, from: $0)
        }
    }
}

extension ConversationSnapshot {
    /// Éléments illisibles ignorés.
    public var backgroundWorks: [BackgroundWork] {
        (state["backgroundWorks"]?.arrayValue ?? []).compactMap { try? V4JSON.decode(BackgroundWork.self, from: $0) }
    }

    /// `state.workflowRuns.runs`, dans l'ordre reçu.
    public var workflowRuns: [WorkflowRun] {
        (state["workflowRuns"]?["runs"]?.arrayValue ?? []).compactMap(WorkflowRun.init(json:))
    }
}

public struct WorkflowPhaseStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pending = WorkflowPhaseStatus(rawValue: "pending")
    public static let running = WorkflowPhaseStatus(rawValue: "running")
    public static let done = WorkflowPhaseStatus(rawValue: "done")
    public static let failed = WorkflowPhaseStatus(rawValue: "failed")
}

/// Résumé d'un run dans l'index des sessions (`workflowActivity.runs[]`).
public struct WorkflowActivityPhase: Codable, Equatable, Sendable {
    public let name: String
    public let status: WorkflowPhaseStatus
}

public struct WorkflowActivity: Codable, Equatable, Sendable {
    public let runId: String
    public let name: String?
    public let status: WorkflowRunStatus
    public let phases: [WorkflowActivityPhase]?
    public let currentPhase: String?
    public let agentsWorking: Int?
}

/// Forme réelle (tâche 0) : un objet `{runs: [...]}`.
public struct WorkflowActivitySummary: Codable, Equatable, Sendable {
    public let runs: [WorkflowActivity]
}
