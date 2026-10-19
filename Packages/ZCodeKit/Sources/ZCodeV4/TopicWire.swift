import Foundation
import ZCodeWire

/// Usage d'une trame physique, fixé par le serveur (`initial` après subscribe, `online` en direct,
/// `recovery` en réponse à une resync).
public enum DeliveryKind: String, Sendable, Hashable {
    case initial, online, recovery
}

/// Route d'une trame : un sujet (`conversation/<id>`, `sessions-index/<workspace>`) et une génération d'abonnement.
public struct WireRoute: Hashable, Sendable {
    public let topic: String
    public let subscriptionId: String

    public init(topic: String, subscriptionId: String) {
        self.topic = topic
        self.subscriptionId = subscriptionId
    }
}

/// Trame logique complète, prête à être appliquée atomiquement.
public struct LogicalFrame: Equatable, Sendable {
    public let route: WireRoute
    public let deliveryKind: DeliveryKind
    public let ordinal: Int
    /// `TopicFrame` brut : `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}`.
    public let frame: JSONValue

    public init(route: WireRoute, deliveryKind: DeliveryKind, ordinal: Int, frame: JSONValue) {
        self.route = route
        self.deliveryKind = deliveryKind
        self.ordinal = ordinal
        self.frame = frame
    }
}

/// Échec d'assemblage d'une trame logique (codes `proto.*` de ZCode).
public struct WireFault: Error, Equatable, Sendable {
    public enum Reason {
        public static let metadataMismatch = "proto.frameAssemblyMetadataMismatch"
        public static let ordinalConflict = "proto.frameAssemblyOrdinalConflict"
        public static let superseded = "proto.frameAssemblySuperseded"
        public static let fragmentCountExceeded = "proto.frameFragmentCountExceeded"
        public static let tooLarge = "proto.frameAssemblyTooLarge"
        public static let invalidBase64 = "proto.frameAssemblyInvalidBase64"
        public static let concurrentLimit = "proto.frameAssemblyConcurrentLimit"
        public static let budgetExceeded = "proto.frameAssemblyBudgetExceeded"
        public static let fragmentConflict = "proto.frameAssemblyFragmentConflict"
        public static let lengthMismatch = "proto.frameAssemblyLengthMismatch"
        public static let checksumMismatch = "proto.frameAssemblyChecksumMismatch"
        public static let invalidUTF8 = "proto.frameAssemblyInvalidUtf8"
        public static let invalidJSON = "proto.frameAssemblyInvalidJson"
        public static let timedOut = "proto.frameAssemblyTimedOut"
        /// Propre à ce client : `wireVersion` ≠ 3 (le serveur a changé de format de trame).
        public static let wireVersionUnsupported = "proto.wireVersionUnsupported"
    }

    public let reasonCode: String
    public let route: WireRoute
    public let ordinal: Int
    public let deliveryKind: DeliveryKind?

    public init(reasonCode: String, route: WireRoute, ordinal: Int, deliveryKind: DeliveryKind?) {
        self.reasonCode = reasonCode
        self.route = route
        self.ordinal = ordinal
        self.deliveryKind = deliveryKind
    }
}

public enum AssemblyEvent: Equatable, Sendable {
    case complete(LogicalFrame)
    case fault(WireFault)
}

/// Limites de `PROTOCOL_V4_LIMITS` (`core.ts`).
public struct WireLimits: Sendable, Equatable {
    public var maxAssemblyBytes = 16 * 1024 * 1024
    public var maxFragments = 1024
    public var maxConcurrentAssemblies = 32
    public var maxStagedBytes = 32 * 1024 * 1024
    public var timeout: Duration = .seconds(30)

    public init() {}

    public static let protocolDefaults = WireLimits()
}
