import Foundation
import ZCodeWire

/// Clés de sujet (`transport.ts`, `sessions-index.ts`).
public enum Topic {
    public static func conversation(_ sessionId: String) -> String { "conversation/\(sessionId)" }
    public static func sessionsIndex(_ workspaceId: String) -> String { "sessions-index/\(workspaceId)" }
}

public struct AckMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// L'état du client est remplacé par un snapshot.
    public static let snapshot = AckMode(rawValue: "snapshot")
    /// La base fournie est valide : seuls les deltas manquants sont renvoyés.
    public static let resume = AckMode(rawValue: "resume")
}

/// Accusé de `subscribe…V4` ou `resync…V4`.
public struct SubscribeAck: Equatable, Sendable {
    public let subscriptionId: String
    public let mode: AckMode
    public let logEpoch: String

    public init(subscriptionId: String, mode: AckMode, logEpoch: String) {
        self.subscriptionId = subscriptionId
        self.mode = mode
        self.logEpoch = logEpoch
    }

    /// Lit `{ack: {subscriptionId, mode, logEpoch, …}}`.
    public init(result: JSONValue) throws(V4DecodingError) {
        let ack = result["ack"] ?? result
        guard let subscriptionId = ack["subscriptionId"]?.stringValue else { throw .missingField("ack.subscriptionId") }
        guard let logEpoch = ack["logEpoch"]?.stringValue else { throw .missingField("ack.logEpoch") }
        self.init(subscriptionId: subscriptionId, mode: AckMode(rawValue: ack["mode"]?.stringValue ?? "snapshot"), logEpoch: logEpoch)
    }
}

/// Position dans le journal d'une session : à renvoyer comme `base` lors d'une resync ou d'un réabonnement.
public struct Watermark: Equatable, Sendable {
    public let logEpoch: String
    public let seq: Int

    public init(logEpoch: String, seq: Int) {
        self.logEpoch = logEpoch
        self.seq = seq
    }

    public var json: JSONValue { .object(["logEpoch": .string(logEpoch), "seq": .number(Double(seq))]) }
}

/// Trame logique d'un sujet : couvre l'intervalle `(fromSeq, toSeq]` du journal.
public struct TopicFrame: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case snapshot(JSONValue)
        case deltas([JSONValue])
        case unknown(String)
    }

    public let topic: String
    public let subscriptionId: String
    public let fromSeq: Int
    public let toSeq: Int
    /// Horloge du serveur (ms) : sert à estimer le décalage d'horloge, jamais à comparer avec l'heure locale.
    public let sentAt: Double?
    public let payload: Payload

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let topic = json["topic"]?.stringValue else { throw .missingField("topic") }
        guard let subscriptionId = json["subscriptionId"]?.stringValue else { throw .missingField("subscriptionId") }
        guard let fromSeq = V4JSON.integer(json["fromSeq"]) else { throw .missingField("fromSeq") }
        guard let toSeq = V4JSON.integer(json["toSeq"]) else { throw .missingField("toSeq") }
        guard let payload = json["payload"] else { throw .missingField("payload") }
        self.topic = topic
        self.subscriptionId = subscriptionId
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.sentAt = json["sentAt"]?.numberValue
        switch payload["kind"]?.stringValue {
        case "snapshot":
            guard let snapshot = payload["snapshot"] else { throw .missingField("payload.snapshot") }
            self.payload = .snapshot(snapshot)
        case "deltas":
            guard let deltas = payload["deltas"]?.arrayValue else { throw .missingField("payload.deltas") }
            self.payload = .deltas(deltas)
        case let kind:
            self.payload = .unknown(kind ?? "")
        }
    }
}

/// Projection d'un sujet : se construit depuis un snapshot et avance par deltas.
public protocol TopicProjection: Equatable, Sendable {
    associatedtype Delta: Sendable
    init(json: JSONValue) throws(V4DecodingError)
    var logEpoch: String { get }
    static func decodeDelta(_ json: JSONValue) -> Delta
    mutating func apply(_ deltas: [Delta])
}

extension ConversationSnapshot: TopicProjection {
    public static func decodeDelta(_ json: JSONValue) -> ConversationDelta { ConversationDelta(json: json) }
}

extension SessionsIndex: TopicProjection {
    public static func decodeDelta(_ json: JSONValue) -> SessionsIndexDelta { SessionsIndexDelta(json: json) }
}
