import Foundation
import ZCodeWire

public struct RowKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let turnHeader = RowKind(rawValue: "turnHeader")
    public static let userInput = RowKind(rawValue: "userInput")
    public static let assistantText = RowKind(rawValue: "assistantText")
    public static let reasoning = RowKind(rawValue: "reasoning")
    public static let toolCall = RowKind(rawValue: "toolCall")
    public static let artifact = RowKind(rawValue: "artifact")
    public static let subagent = RowKind(rawValue: "subagent")
    public static let hookInvocation = RowKind(rawValue: "hookInvocation")
    public static let timelineMarker = RowKind(rawValue: "timelineMarker")
}

/// Champ de texte qu'un `row.delta` peut compléter.
public struct StreamablePath: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let text = StreamablePath(rawValue: "text")
    public static let inputText = StreamablePath(rawValue: "inputText")
    public static let outputText = StreamablePath(rawValue: "output.text")
    public static let summaryText = StreamablePath(rawValue: "summaryText")
}

public struct TurnState: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let running = TurnState(rawValue: "running")
    public static let completedSuccess = TurnState(rawValue: "completedSuccess")
    public static let completedInterrupted = TurnState(rawValue: "completedInterrupted")
    public static let failed = TurnState(rawValue: "failed")
}

public struct TextState: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let streaming = TextState(rawValue: "streaming")
    public static let complete = TextState(rawValue: "complete")
    public static let interrupted = TextState(rawValue: "interrupted")
    public static let failed = TextState(rawValue: "failed")
}

public struct ToolCallStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let inputStreaming = ToolCallStatus(rawValue: "inputStreaming")
    public static let pendingApproval = ToolCallStatus(rawValue: "pendingApproval")
    public static let running = ToolCallStatus(rawValue: "running")
    public static let success = ToolCallStatus(rawValue: "success")
    public static let error = ToolCallStatus(rawValue: "error")
    public static let cancelled = ToolCallStatus(rawValue: "cancelled")
}

public struct FileChangeSummary: Decodable, Equatable, Sendable {
    public let additions: Int
    public let deletions: Int
    public let files: Int
    public let state: String?
}

/// En-tête de tour : état, durées, fichiers modifiés.
public struct TurnHeader: Decodable, Equatable, Sendable {
    public let origin: String?
    public let state: TurnState
    public let startedAt: Double?
    public let endedAt: Double?
    public let activeMs: Double?
    public let outputTokens: Int?
    public let sourceCommandId: String?
    public let fileChanges: FileChangeSummary?
}

public struct UserInput: Decodable, Equatable, Sendable {
    public let text: String
    public let origin: String?
    public let inputOrigin: String?
    public let guided: Bool?
    public let clientId: String?
    public let sourceCommandId: String?
    /// Pièces jointes du message ; une entrée illisible est ignorée.
    public let attachments: [AttachmentRef]

    private enum CodingKeys: String, CodingKey {
        case text, origin, inputOrigin, guided, clientId, sourceCommandId, attachments
    }

    /// Une entrée de `attachments` ; `nil` si elle ne se décode pas.
    private struct TolerantAttachment: Decodable {
        let value: AttachmentRef?
        init(from decoder: any Decoder) throws { value = try? AttachmentRef(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        inputOrigin = try container.decodeIfPresent(String.self, forKey: .inputOrigin)
        guided = try container.decodeIfPresent(Bool.self, forKey: .guided)
        clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        sourceCommandId = try container.decodeIfPresent(String.self, forKey: .sourceCommandId)
        attachments = ((try? container.decodeIfPresent([TolerantAttachment].self, forKey: .attachments)) ?? nil)?
            .compactMap(\.value) ?? []
    }
}

public struct AssistantText: Decodable, Equatable, Sendable {
    public let text: String
    public let state: TextState
    public let model: String?
}

public struct Reasoning: Decodable, Equatable, Sendable {
    public let text: String
    public let state: TextState
    public let durationMs: Double?
}

public struct ToolOutput: Decodable, Equatable, Sendable {
    public struct Truncation: Decodable, Equatable, Sendable {
        public let totalBytes: Double
        public let ref: String
    }

    public let text: String
    public let truncated: Truncation?
    /// Diff produit par l'hôte (`display` de kind `file_diff`) ; `nil` pour tout autre `display`.
    public let fileDiff: FileDiffDisplay?

    private enum CodingKeys: String, CodingKey {
        case text, truncated, display
    }

    init(text: String, truncated: Truncation?, fileDiff: FileDiffDisplay?) {
        self.text = text
        self.truncated = truncated
        self.fileDiff = fileDiff
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        truncated = try container.decodeIfPresent(Truncation.self, forKey: .truncated)
        // Comme l'hôte (`.catch(undefined)`) : un `display` inconnu ou illisible ne fait pas perdre la ligne.
        fileDiff = FileDiffDisplay(json: try? container.decodeIfPresent(JSONValue.self, forKey: .display))
    }
}

/// Diff d'un Edit ou d'un Write qui modifie un fichier (`output.display`, kind `file_diff`) : numéros de ligne réels,
/// 8 hunks et 160 lignes au plus (`truncated`), compteurs calculés avant la troncature. Un Write qui crée un fichier
/// n'en a jamais (ZCode 3.15.1).
public struct FileDiffDisplay: Equatable, Sendable {
    public let filePath: String
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiffHunk]
    public let truncated: Bool

    init?(json: JSONValue?) {
        guard let json, json["kind"]?.stringValue == "file_diff",
              let path = json["filePath"]?.stringValue, !path.isEmpty,
              let patch = json["structuredPatch"]?.arrayValue else { return nil }
        filePath = path
        additions = V4JSON.integer(json["additions"]) ?? 0
        deletions = V4JSON.integer(json["deletions"]) ?? 0
        hunks = patch.compactMap { try? V4JSON.decode(DiffHunk.self, from: $0) }
        truncated = json["truncated"]?.boolValue ?? false
    }
}

public struct ToolError: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct ToolCall: Decodable, Equatable, Sendable {
    public let toolCallId: String
    public let toolName: String
    public let status: ToolCallStatus
    public let inputText: String
    /// Arguments décodés (forme propre à chaque outil) ; affichage générique.
    public let input: JSONValue?
    public let output: ToolOutput?
    public let error: ToolError?
    public let approvalInteractionId: String?
    public let startedAt: Double?
    public let endedAt: Double?

    func with(inputText: String, output: ToolOutput?) -> ToolCall {
        ToolCall(toolCallId: toolCallId, toolName: toolName, status: status, inputText: inputText, input: input,
                 output: output, error: error, approvalInteractionId: approvalInteractionId,
                 startedAt: startedAt, endedAt: endedAt)
    }
}

public struct Subagent: Decodable, Equatable, Sendable {
    public let subagentType: String
    /// `running | success | failed | cancelled` ; valeur inconnue gardée telle quelle.
    public let status: String
    public let summaryText: String
    /// Présent ⇒ la conversation de l'enfant s'ouvre par `conversation/<childSessionId>` (lot 13D).
    public let childSessionId: String?
    /// Appel d'outil Agent / Task qui a lancé le sous-agent (association de la carte, lot 13D).
    public let parentToolCallId: String?
    public let backgrounded: Bool
    public let startedAt: Double?
    public let endedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case subagentType, status, summaryText, childSessionId, parentToolCallId, backgrounded, startedAt, endedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subagentType = try container.decode(String.self, forKey: .subagentType)
        status = try container.decode(String.self, forKey: .status)
        summaryText = try container.decode(String.self, forKey: .summaryText)
        // Champs optionnels : un type inattendu vaut absence, la ligne reste lisible.
        childSessionId = (try? container.decodeIfPresent(String.self, forKey: .childSessionId)) ?? nil
        parentToolCallId = (try? container.decodeIfPresent(String.self, forKey: .parentToolCallId)) ?? nil
        backgrounded = ((try? container.decodeIfPresent(Bool.self, forKey: .backgrounded)) ?? nil) ?? false
        startedAt = (try? container.decodeIfPresent(Double.self, forKey: .startedAt)) ?? nil
        endedAt = (try? container.decodeIfPresent(Double.self, forKey: .endedAt)) ?? nil
    }

    private init(copying other: Subagent, summaryText: String) {
        subagentType = other.subagentType
        status = other.status
        self.summaryText = summaryText
        childSessionId = other.childSessionId
        parentToolCallId = other.parentToolCallId
        backgrounded = other.backgrounded
        startedAt = other.startedAt
        endedAt = other.endedAt
    }

    func with(summaryText: String) -> Subagent { Subagent(copying: self, summaryText: summaryText) }
}

/// Marqueur de chronologie (compactage, changement de modèle, Goal…), affiché selon `marker.type`.
public struct TimelineMarker: Decodable, Equatable, Sendable {
    public let lane: String?
    public let marker: JSONValue
    public var markerType: String? { marker["type"]?.stringValue }
}

/// Ligne d'une conversation ZCode. Le JSON complet est conservé ; `content` en est la lecture typée.
public struct ConversationRow: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case turnHeader(TurnHeader)
        case userInput(UserInput)
        case assistantText(AssistantText)
        case reasoning(Reasoning)
        case toolCall(ToolCall)
        case subagent(Subagent)
        case timelineMarker(TimelineMarker)
        /// Type inconnu, type non modélisé (`artifact`, `hookInvocation`) ou ligne mal formée :
        /// l'app affiche une carte générique à partir de `raw`.
        case unsupported
    }

    public let rowId: Int
    public let kind: RowKind
    public let raw: [String: JSONValue]
    public let content: Content

    public var id: Int { rowId }
    public var turnId: String? { raw["turnId"]?.stringValue }
    public var entityId: String? { raw["entityId"]?.stringValue }
    /// Actions permises par l'hôte sur cette ligne (clés absentes = non permises).
    public var actions: RowActions { RowActions(json: raw["actions"]) }
    public var createdAt: Double? { raw["createdAt"]?.numberValue }
    public var json: JSONValue { .object(raw) }

    /// `nil` seulement si la valeur n'est pas un objet muni d'un `rowId` entier (ligne impossible à placer).
    public init?(json: JSONValue) {
        guard let object = json.objectValue, let rowId = V4JSON.integer(object["rowId"]) else { return nil }
        let kind = RowKind(rawValue: object["kind"]?.stringValue ?? "")
        self.rowId = rowId
        self.kind = kind
        self.raw = object
        self.content = Self.decodeContent(kind: kind, json: json)
    }

    private init(rowId: Int, kind: RowKind, raw: [String: JSONValue], content: Content) {
        self.rowId = rowId
        self.kind = kind
        self.raw = raw
        self.content = content
    }

    /// Applique un `row.delta` (`apply.ts`, `appendToRow`) ; chemin sans objet pour ce type → ligne inchangée.
    public func appending(_ text: String, at path: StreamablePath) -> ConversationRow {
        if let fast = appendingDecoded(text, at: path) { return fast }
        // Ligne mal formée (contenu `.unsupported`) : on complète le JSON puis on retente le décodage.
        var raw = self.raw
        if path == .text, kind == .assistantText || kind == .reasoning {
            raw["text"] = .string((raw["text"]?.stringValue ?? "") + text)
        } else if path == .inputText, kind == .toolCall {
            raw["inputText"] = .string((raw["inputText"]?.stringValue ?? "") + text)
        } else if path == .outputText, kind == .toolCall, var output = raw["output"]?.objectValue {
            output["text"] = .string((output["text"]?.stringValue ?? "") + text)
            raw["output"] = .object(output)
        } else if path == .summaryText, kind == .subagent {
            raw["summaryText"] = .string((raw["summaryText"]?.stringValue ?? "") + text)
        } else {
            return self
        }
        return ConversationRow(json: .object(raw)) ?? self
    }

    /// Mise à jour directe du contenu typé et du JSON, sans passer par `JSONEncoder`/`JSONDecoder` (le streaming
    /// d'une longue réponse envoie des milliers de deltas). `nil` si la ligne n'est pas décodée pour ce chemin.
    private func appendingDecoded(_ text: String, at path: StreamablePath) -> ConversationRow? {
        var raw = self.raw
        let content: Content
        switch (self.content, path) {
        case (.assistantText(let value), .text):
            let updated = value.text + text
            raw["text"] = .string(updated)
            content = .assistantText(AssistantText(text: updated, state: value.state, model: value.model))
        case (.reasoning(let value), .text):
            let updated = value.text + text
            raw["text"] = .string(updated)
            content = .reasoning(Reasoning(text: updated, state: value.state, durationMs: value.durationMs))
        case (.toolCall(let value), .inputText):
            let updated = value.inputText + text
            raw["inputText"] = .string(updated)
            content = .toolCall(value.with(inputText: updated, output: value.output))
        case (.toolCall(let value), .outputText):
            guard let output = value.output, var rawOutput = raw["output"]?.objectValue else { return nil }
            let updated = output.text + text
            rawOutput["text"] = .string(updated)
            raw["output"] = .object(rawOutput)
            content = .toolCall(value.with(inputText: value.inputText,
                                           output: ToolOutput(text: updated, truncated: output.truncated, fileDiff: output.fileDiff)))
        case (.subagent(let value), .summaryText):
            let updated = value.summaryText + text
            raw["summaryText"] = .string(updated)
            content = .subagent(value.with(summaryText: updated))
        case (.unsupported, _):
            return nil
        default:
            return self                                    // chemin sans objet pour ce type
        }
        return ConversationRow(rowId: rowId, kind: kind, raw: raw, content: content)
    }

    private static func decodeContent(kind: RowKind, json: JSONValue) -> Content {
        do {
            switch kind {
            case .turnHeader: return .turnHeader(try V4JSON.decode(TurnHeader.self, from: json))
            case .userInput: return .userInput(try V4JSON.decode(UserInput.self, from: json))
            case .assistantText: return .assistantText(try V4JSON.decode(AssistantText.self, from: json))
            case .reasoning: return .reasoning(try V4JSON.decode(Reasoning.self, from: json))
            case .toolCall: return .toolCall(try V4JSON.decode(ToolCall.self, from: json))
            case .subagent: return .subagent(try V4JSON.decode(Subagent.self, from: json))
            case .timelineMarker: return .timelineMarker(try V4JSON.decode(TimelineMarker.self, from: json))
            default: return .unsupported
            }
        } catch {
            return .unsupported
        }
    }
}

/// Actions d'une ligne (`rowBaseFields.actions`) : l'hôte n'envoie que les clés vraies.
public struct RowActions: Equatable, Sendable {
    /// Seule la dernière réponse issue d'un vrai message peut être relancée (`retryTurn`).
    public let canRetry: Bool
    public let canEdit: Bool
    public let canFork: Bool
    public let canRewindFiles: Bool

    public init(canRetry: Bool, canEdit: Bool, canFork: Bool, canRewindFiles: Bool) {
        self.canRetry = canRetry
        self.canEdit = canEdit
        self.canFork = canFork
        self.canRewindFiles = canRewindFiles
    }

    init(json: JSONValue?) {
        self.init(canRetry: json?["canRetry"]?.boolValue == true, canEdit: json?["canEdit"]?.boolValue == true,
                  canFork: json?["canFork"]?.boolValue == true, canRewindFiles: json?["canRewindFiles"]?.boolValue == true)
    }
}
