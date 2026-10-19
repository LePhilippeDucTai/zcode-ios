import Foundation
import ZCodeWire

public enum V4Protocol {
    /// Version du format de trame (`hello.protocolVersion`) ; une autre valeur bloque la connexion.
    public static let wireVersion = 3
    /// Version des projections (`snapshot.protocolVersion`, `sessionsIndex.protocolVersion`), distincte.
    public static let projectionVersion = 1
    /// Dernière version de ZCode vérifiée par `zcode-probe check` ; une version plus récente → simple avertissement.
    public static let lastTestedServerVersion = "3.15.1"
    public static let agentChannel = "zcode-agent"
    public static let rowsRangeMaxLimit = 200
}

public struct HostCapabilities: Decodable, Equatable, Sendable {
    public let nativeDialogs: Bool?
    public let localTerminal: Bool?
    public let binaryFrames: Bool?
    public let compression: String?
    public let workspaceHookReview: Bool?
    public let independentPlanState: Bool?
    public let workflowRunDeltas: Bool?
}

/// Premier message du serveur (`helloConversationV4`). Seul `protocolVersion` est exigé : un autre champ absent
/// ou renommé par une version plus récente de ZCode ne doit pas empêcher la connexion.
public struct HelloMessage: Decodable, Equatable, Sendable {
    public let kind: String?
    public let protocolVersion: Int
    public let connectionId: String?
    public let clientMode: String?
    public let deliveryProfile: String?
    public let serverTime: Double?
    public let capabilities: HostCapabilities?
}

/// Réponse au `hello` (`initializeConversationV4`). Sans `capabilities` : l'objet est strict côté serveur
/// et ce client ne déclare aucune capacité optionnelle.
public struct ClientHello: Equatable, Sendable {
    public let clientId: String
    public let appVersion: String

    public init(clientId: String, appVersion: String) {
        self.clientId = clientId
        self.appVersion = appVersion
    }

    public var json: JSONValue {
        .object([
            "kind": .string("clientHello"),
            "protocolVersion": .number(Double(V4Protocol.wireVersion)),
            "clientId": .string(clientId),
            "clientKind": .string("mobileApp"),
            "appVersion": .string(appVersion),
        ])
    }
}

/// Page d'historique (`conversationRowsRangeV4`), `rowId` croissants.
public struct RowsRangePage: Equatable, Sendable {
    public let rows: [ConversationRow]
    public let atSeq: Int
    public let atRevision: Int
    public let atLogEpoch: String
    /// Il reste des lignes plus anciennes.
    public let hasMore: Bool

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let rows = json["rows"]?.arrayValue else { throw .missingField("rows") }
        guard let atLogEpoch = json["atLogEpoch"]?.stringValue else { throw .missingField("atLogEpoch") }
        self.rows = rows.compactMap(ConversationRow.init(json:))
        self.atSeq = V4JSON.integer(json["atSeq"]) ?? 0
        self.atRevision = V4JSON.integer(json["atRevision"]) ?? 0
        self.atLogEpoch = atLogEpoch
        self.hasMore = json["hasMore"]?.boolValue ?? false
    }
}

/// Ligne visée par une commande ou une requête (`conversationRowTargetSchema`).
public struct RowTarget: Hashable, Sendable {
    public let rowId: Int
    public let entityId: String

    public init(rowId: Int, entityId: String) {
        self.rowId = rowId
        self.entityId = entityId
    }

    /// `nil` si la ligne n'a pas d'`entityId` (elle ne peut pas être visée).
    public init?(row: ConversationRow) {
        guard let entityId = row.entityId, !entityId.isEmpty else { return nil }
        self.init(rowId: row.rowId, entityId: entityId)
    }

    public var json: JSONValue { .object(["rowId": .number(Double(rowId)), "entityId": .string(entityId)]) }
}

public struct DiffHunk: Decodable, Hashable, Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    /// Lignes préfixées par `+`, `-` ou une espace.
    public let lines: [String]
}

public struct FileChangeItem: Decodable, Hashable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let writeCount: Int
    public let toolNames: [String]
    public let patches: [DiffHunk]
}

/// Fichiers modifiés par un tour (`conversationFileChangesV4`).
public struct FileChanges: Decodable, Equatable, Sendable {
    public let files: Int
    public let additions: Int
    public let deletions: Int
    public let state: String?
    public let items: [FileChangeItem]
}
