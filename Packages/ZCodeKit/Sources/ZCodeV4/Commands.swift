import Foundation
import ZCodeWire

public struct CommandType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let createSession = CommandType(rawValue: "createSession")
    public static let sendText = CommandType(rawValue: "sendText")
    public static let sendGoalCommand = CommandType(rawValue: "sendGoalCommand")
    public static let stop = CommandType(rawValue: "stop")
    public static let compact = CommandType(rawValue: "compact")
    public static let forkAssistant = CommandType(rawValue: "forkAssistant")
    public static let applyFileRewind = CommandType(rawValue: "applyFileRewind")
    public static let editUserQuery = CommandType(rawValue: "editUserQuery")
    public static let retryTurn = CommandType(rawValue: "retryTurn")
    public static let setAssistantFeedback = CommandType(rawValue: "setAssistantFeedback")
    public static let setHighspeedMetrics = CommandType(rawValue: "setHighspeedMetrics")
    public static let sendQueuedNow = CommandType(rawValue: "sendQueuedNow")
    public static let editQueueItem = CommandType(rawValue: "editQueueItem")
    public static let reorderQueueItem = CommandType(rawValue: "reorderQueueItem")
    public static let deleteQueueItem = CommandType(rawValue: "deleteQueueItem")
    public static let setAutoDrain = CommandType(rawValue: "setAutoDrain")
    public static let resolveInteraction = CommandType(rawValue: "resolveInteraction")
    public static let snoozeInteractionAutoResolution = CommandType(rawValue: "snoozeInteractionAutoResolution")
    public static let switchModelConfig = CommandType(rawValue: "switchModelConfig")
    public static let switchCollaborationMode = CommandType(rawValue: "switchCollaborationMode")
    public static let setFollowupMode = CommandType(rawValue: "setFollowupMode")
    public static let pauseGoal = CommandType(rawValue: "pauseGoal")
    public static let resumeGoal = CommandType(rawValue: "resumeGoal")
    public static let cancelBackgroundWork = CommandType(rawValue: "cancelBackgroundWork")
    public static let renameSession = CommandType(rawValue: "renameSession")
    public static let deleteSession = CommandType(rawValue: "deleteSession")
    /// Workflow enregistré lancé sur une session neuve (`{name, scope?, args?}` → `{type, runId, toolCallId}`) ;
    /// ni CAS ni ciblage de ligne.
    public static let startSavedWorkflow = CommandType(rawValue: "startSavedWorkflow")

    /// `COMMANDS_REQUIRING_BASE_REVISION` de `command.ts`.
    public static let requiringBaseRevision: Set<CommandType> = [
        .applyFileRewind, .forkAssistant, .editUserQuery, .retryTurn, .setAssistantFeedback, .sendQueuedNow,
        .editQueueItem, .reorderQueueItem, .deleteQueueItem, .setAutoDrain, .switchModelConfig,
        .switchCollaborationMode, .setFollowupMode, .pauseGoal, .resumeGoal,
    ]

    /// `ROW_TARGETING_COMMANDS` de `command.ts` : `baseLogEpoch` obligatoire.
    public static let targetingRows: Set<CommandType> = [
        .applyFileRewind, .forkAssistant, .editUserQuery, .retryTurn, .setAssistantFeedback, .setHighspeedMetrics,
    ]
}

public struct CommandKey: Hashable, Sendable {
    /// `nil` pour `createSession` (pas encore de session).
    public let sessionId: String?
    public let commandId: String

    public init(sessionId: String?, commandId: String) {
        self.sessionId = sessionId
        self.commandId = commandId
    }

    public var json: JSONValue {
        .object(["sessionId": sessionId.map(JSONValue.string) ?? .null, "commandId": .string(commandId)])
    }
}

/// Enveloppe d'une commande (`commandEnvelopeSchema`). `commandId` est stable : le renvoyer tel quel en cas de doute.
public struct CommandEnvelope: Equatable, Sendable {
    public let commandId: String
    public let clientId: String
    public let sessionId: String?
    public let baseRevision: Int?
    public let baseLogEpoch: String?
    public let type: CommandType
    public let payload: JSONValue
    /// Horloge du client en ms (télémétrie seulement).
    public let issuedAt: Int64

    public init(
        commandId: String, clientId: String, sessionId: String?, baseRevision: Int?, baseLogEpoch: String?,
        type: CommandType, payload: JSONValue, issuedAt: Int64
    ) {
        self.commandId = commandId
        self.clientId = clientId
        self.sessionId = sessionId
        self.baseRevision = baseRevision
        self.baseLogEpoch = baseLogEpoch
        self.type = type
        self.payload = payload
        self.issuedAt = issuedAt
    }

    public var key: CommandKey { CommandKey(sessionId: sessionId, commandId: commandId) }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "commandId": .string(commandId),
            "clientId": .string(clientId),
            // `null` explicite pour `createSession` : la clé est obligatoire.
            "sessionId": sessionId.map(JSONValue.string) ?? .null,
            "type": .string(type.rawValue),
            "payload": payload,
            "issuedAt": .number(Double(issuedAt)),
        ]
        if let baseRevision { object["baseRevision"] = .number(Double(baseRevision)) }
        if let baseLogEpoch { object["baseLogEpoch"] = .string(baseLogEpoch) }
        return .object(object)
    }
}

public struct CommandStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let accepted = CommandStatus(rawValue: "accepted")
    public static let rejected = CommandStatus(rawValue: "rejected")
    public static let stale = CommandStatus(rawValue: "stale")
    public static let duplicate = CommandStatus(rawValue: "duplicate")
    public static let noop = CommandStatus(rawValue: "noop")
    public static let failed = CommandStatus(rawValue: "failed")
}

public struct CommandResult: Equatable, Sendable {
    public let type: String
    /// Présent pour `createSession`, `createSelectionSideSession`, `forkAssistant`.
    public let sessionId: String?
    /// Pour `sendText` : ce que l'hôte a fait du message (`startNow`, `queue`, `guide`), qui fait foi.
    public let delivery: String?
    public let raw: JSONValue
}

/// Accusé d'une commande (`commandAckSchema`).
public struct CommandAck: Equatable, Sendable {
    public let commandId: String
    public let status: CommandStatus
    public let reasonCode: String?
    public let message: String?
    public let revisionAtDecision: Int?
    public let result: CommandResult?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let commandId = json["commandId"]?.stringValue else { throw .missingField("commandId") }
        guard let status = json["status"]?.stringValue else { throw .missingField("status") }
        self.commandId = commandId
        self.status = CommandStatus(rawValue: status)
        self.reasonCode = json["reasonCode"]?.stringValue
        self.message = json["message"]?.stringValue
        self.revisionAtDecision = V4JSON.integer(json["revisionAtDecision"])
        if let result = json["result"], let type = result["type"]?.stringValue {
            self.result = CommandResult(
                type: type, sessionId: result["sessionId"]?.stringValue,
                delivery: result["delivery"]?.stringValue, raw: result)
        } else {
            self.result = nil
        }
    }

    /// La commande a été prise en compte (un doublon rejoue le résultat d'une commande déjà acceptée).
    public var isAccepted: Bool { status == .accepted || status == .duplicate }
}

public enum CommandQueryResult: Equatable, Sendable {
    case known(CommandAck)
    /// Le serveur n'a aucune trace de cette commande : elle peut être renvoyée avec le même `commandId`.
    case unknown
}

public struct CommandQueryItem: Equatable, Sendable {
    public let key: CommandKey
    public let result: CommandQueryResult
}

/// Résultat de `queryConversationCommandsV4` (rapprochement après reconnexion).
public enum CommandsQuery {
    public static func parse(_ json: JSONValue) throws(V4DecodingError) -> [CommandQueryItem] {
        guard let results = json["results"]?.arrayValue else { throw .missingField("results") }
        var items: [CommandQueryItem] = []
        for item in results {
            guard let commandId = item["key"]?["commandId"]?.stringValue else { throw .missingField("results.key.commandId") }
            let key = CommandKey(sessionId: item["key"]?["sessionId"]?.stringValue, commandId: commandId)
            if let ack = item["result"], ack.objectValue != nil {
                items.append(CommandQueryItem(key: key, result: .known(try CommandAck(json: ack))))
            } else {
                items.append(CommandQueryItem(key: key, result: .unknown))
            }
        }
        return items
    }
}
