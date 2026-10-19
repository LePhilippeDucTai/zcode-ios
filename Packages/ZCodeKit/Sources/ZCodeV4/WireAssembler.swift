import Foundation
import ZCodeWire

/// Réassemble les trames physiques (`complete` / `fragment`) en trames logiques.
///
/// Port de `TopicWireFrameAssembler` (`wire-assembler.ts`) : un assemblage actif et une « pierre tombale »
/// (dernier ordinal traité) par route ; les fragments ne sont publiés qu'une fois tous reçus et vérifiés
/// (longueur, CRC32, UTF-8, JSON, route). Contrairement à ZCode, le contenu n'est pas validé par schéma ici :
/// le décodage tolérant se fait plus haut.
public struct WireAssembler: Sendable {
    private struct Assembly: Sendable {
        let deliveryKind: DeliveryKind
        let logicalFrameId: String
        let ordinal: Int
        let fragmentCount: Int
        let logicalBytes: Int
        let checksum: String
        var fragments: [Data?]
        var receivedCount = 0
        var decodedBytes = 0
        let firstSeenAt: ContinuousClock.Instant
    }

    private struct Settled: Sendable {
        let logicalFrameId: String
        let ordinal: Int
    }

    public let limits: WireLimits
    private var assemblies: [WireRoute: Assembly] = [:]
    private var settled: [WireRoute: Settled] = [:]
    /// Octets décodés en attente, toutes routes confondues.
    public private(set) var stagedBytes = 0

    public init(limits: WireLimits = .protocolDefaults) {
        self.limits = limits
    }

    public var activeAssemblyCount: Int { assemblies.count }

    /// Prochaine échéance d'un assemblage incomplet (pour appeler `expire(now:)` même sans nouvelle trame).
    public var nextDeadline: ContinuousClock.Instant? {
        assemblies.values.map { $0.firstSeenAt.advanced(by: limits.timeout) }.min()
    }

    public mutating func accept(_ wire: JSONValue, now: ContinuousClock.Instant) -> [AssemblyEvent] {
        var events = expire(now: now)
        // Enveloppe non routable : impossible d'attribuer une faute, on l'ignore (frontière de service ZCode).
        guard let topic = wire["topic"]?.stringValue, !topic.isEmpty,
              let subscriptionId = wire["subscriptionId"]?.stringValue, !subscriptionId.isEmpty,
              let logicalFrameId = wire["logicalFrameId"]?.stringValue, !logicalFrameId.isEmpty
        else { return events }
        let route = WireRoute(topic: topic, subscriptionId: subscriptionId)
        // `nil` si absent ou inconnu : la faute est alors signalée sans usage.
        let parsedDelivery = wire["deliveryKind"]?.stringValue.flatMap(DeliveryKind.init(rawValue:))
        guard let ordinal = V4JSON.integer(wire["logicalFrameOrdinal"]), ordinal >= 1 else {
            events.append(.fault(WireFault(reasonCode: WireFault.Reason.metadataMismatch, route: route, ordinal: 0, deliveryKind: parsedDelivery)))
            return events
        }
        func fault(_ reason: String) -> AssemblyEvent {
            .fault(WireFault(reasonCode: reason, route: route, ordinal: ordinal, deliveryKind: parsedDelivery))
        }

        if let done = settled[route] {
            if ordinal < done.ordinal { return events }
            if ordinal == done.ordinal {
                if logicalFrameId != done.logicalFrameId { events.append(fault(WireFault.Reason.ordinalConflict)) }
                return events
            }
        }
        if parsedDelivery == .recovery {
            // Une trame de reprise rend caduques les fautes plus anciennes de la même route.
            events.removeAll { event in
                if case .fault(let old) = event { return old.route == route && old.ordinal < ordinal }
                return false
            }
        }
        if let current = assemblies[route] {
            if ordinal < current.ordinal { return events }
            if ordinal == current.ordinal {
                if logicalFrameId != current.logicalFrameId {
                    release(route)
                    settle(route, id: current.logicalFrameId, ordinal: current.ordinal)
                    events.append(fault(WireFault.Reason.ordinalConflict))
                    return events
                }
            } else {
                release(route)
                settle(route, id: current.logicalFrameId, ordinal: current.ordinal)
                if parsedDelivery != .recovery {
                    events.append(.fault(WireFault(
                        reasonCode: WireFault.Reason.superseded, route: route,
                        ordinal: current.ordinal, deliveryKind: current.deliveryKind)))
                }
            }
        }
        guard V4JSON.integer(wire["wireVersion"]) == 3 else {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            events.append(fault(WireFault.Reason.wireVersionUnsupported))
            return events
        }
        guard let deliveryKind = parsedDelivery else {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            events.append(fault(WireFault.Reason.metadataMismatch))
            return events
        }

        switch wire["kind"]?.stringValue {
        case "complete":
            if let active = assemblies[route] {
                // Des fragments étaient en cours pour ce même ordinal : incohérent.
                release(route)
                settle(route, id: active.logicalFrameId, ordinal: active.ordinal)
                events.append(fault(WireFault.Reason.metadataMismatch))
                return events
            }
            settle(route, id: logicalFrameId, ordinal: ordinal)
            guard let frame = wire["frame"],
                  frame["topic"]?.stringValue == topic,
                  frame["subscriptionId"]?.stringValue == subscriptionId
            else {
                events.append(fault(WireFault.Reason.metadataMismatch))
                return events
            }
            events.append(.complete(LogicalFrame(route: route, deliveryKind: deliveryKind, ordinal: ordinal, frame: frame)))
        case "fragment":
            events.append(contentsOf: acceptFragment(
                wire, route: route, logicalFrameId: logicalFrameId, ordinal: ordinal,
                deliveryKind: deliveryKind, now: now))
        default:
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            events.append(fault(WireFault.Reason.metadataMismatch))
        }
        return events
    }

    /// Fait expirer les assemblages commencés depuis plus de `limits.timeout`.
    public mutating func expire(now: ContinuousClock.Instant) -> [AssemblyEvent] {
        var events: [AssemblyEvent] = []
        for (route, assembly) in assemblies where now >= assembly.firstSeenAt.advanced(by: limits.timeout) {
            release(route)
            settle(route, id: assembly.logicalFrameId, ordinal: assembly.ordinal)
            events.append(.fault(WireFault(
                reasonCode: WireFault.Reason.timedOut, route: route,
                ordinal: assembly.ordinal, deliveryKind: assembly.deliveryKind)))
        }
        return events
    }

    /// Oublie une route (désabonnement, nouvel abonnement) : assemblage en cours et pierre tombale.
    public mutating func discard(_ route: WireRoute) {
        release(route)
        settled[route] = nil
    }

    // MARK: - Fragments

    private mutating func acceptFragment(
        _ wire: JSONValue,
        route: WireRoute,
        logicalFrameId: String,
        ordinal: Int,
        deliveryKind: DeliveryKind,
        now: ContinuousClock.Instant
    ) -> [AssemblyEvent] {
        func fault(_ reason: String) -> [AssemblyEvent] {
            [.fault(WireFault(reasonCode: reason, route: route, ordinal: ordinal, deliveryKind: deliveryKind))]
        }
        guard let index = V4JSON.integer(wire["fragmentIndex"]),
              let count = V4JSON.integer(wire["fragmentCount"]),
              let logicalBytes = V4JSON.integer(wire["logicalBytes"]),
              let dataBase64 = wire["dataBase64"]?.stringValue,
              let algorithm = wire["checksum"]?["algorithm"]?.stringValue,
              let checksum = wire["checksum"]?["value"]?.stringValue
        else {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.metadataMismatch)
        }
        if count > limits.maxFragments {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.fragmentCountExceeded)
        }
        if logicalBytes > limits.maxAssemblyBytes {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.tooLarge)
        }
        guard count >= 1, index >= 0, index < count, logicalBytes >= 1, count <= logicalBytes,
              algorithm == "crc32", Self.isLowercaseHex8(checksum)
        else {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.metadataMismatch)
        }
        guard let decoded = WireBase64.decode(dataBase64) else {
            releaseAndSettle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.invalidBase64)
        }

        var assembly: Assembly
        if let existing = assemblies[route] {
            guard existing.fragmentCount == count, existing.deliveryKind == deliveryKind,
                  existing.logicalBytes == logicalBytes, existing.checksum == checksum
            else {
                release(route)
                settle(route, id: existing.logicalFrameId, ordinal: existing.ordinal)
                return fault(WireFault.Reason.metadataMismatch)
            }
            assembly = existing
        } else {
            if assemblies.count >= limits.maxConcurrentAssemblies {
                settle(route, id: logicalFrameId, ordinal: ordinal)
                return fault(WireFault.Reason.concurrentLimit)
            }
            if stagedBytes + decoded.count > limits.maxStagedBytes {
                settle(route, id: logicalFrameId, ordinal: ordinal)
                return fault(WireFault.Reason.budgetExceeded)
            }
            assembly = Assembly(
                deliveryKind: deliveryKind, logicalFrameId: logicalFrameId, ordinal: ordinal,
                fragmentCount: count, logicalBytes: logicalBytes, checksum: checksum,
                fragments: Array(repeating: nil, count: count), firstSeenAt: now)
        }

        if let previous = assembly.fragments[index] {
            guard previous == decoded else {
                release(route)
                settle(route, id: logicalFrameId, ordinal: ordinal)
                return fault(WireFault.Reason.fragmentConflict)
            }
            return []
        }
        if stagedBytes + decoded.count > limits.maxStagedBytes {
            release(route)
            settle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.budgetExceeded)
        }
        if assembly.decodedBytes + decoded.count > logicalBytes {
            release(route)
            settle(route, id: logicalFrameId, ordinal: ordinal)
            return fault(WireFault.Reason.lengthMismatch)
        }
        // L'ancienne copie éventuelle est retirée du budget avant d'enregistrer la nouvelle.
        release(route)
        assembly.fragments[index] = decoded
        assembly.receivedCount += 1
        assembly.decodedBytes += decoded.count
        guard assembly.receivedCount == count else {
            assemblies[route] = assembly
            stagedBytes += assembly.decodedBytes
            return []
        }

        settle(route, id: logicalFrameId, ordinal: ordinal)
        guard assembly.decodedBytes == logicalBytes else { return fault(WireFault.Reason.lengthMismatch) }
        var logical = Data(capacity: logicalBytes)
        for fragment in assembly.fragments {
            guard let fragment else { return fault(WireFault.Reason.lengthMismatch) }
            logical.append(fragment)
        }
        guard CRC32.hex(logical) == checksum else { return fault(WireFault.Reason.checksumMismatch) }
        guard String(validating: logical, as: UTF8.self) != nil else { return fault(WireFault.Reason.invalidUTF8) }
        guard let frame = try? JSONValue.decode(logical) else { return fault(WireFault.Reason.invalidJSON) }
        guard frame["topic"]?.stringValue == route.topic, frame["subscriptionId"]?.stringValue == route.subscriptionId else {
            return fault(WireFault.Reason.metadataMismatch)
        }
        return [.complete(LogicalFrame(route: route, deliveryKind: deliveryKind, ordinal: ordinal, frame: frame))]
    }

    // MARK: - Interne

    private mutating func release(_ route: WireRoute) {
        if let assembly = assemblies.removeValue(forKey: route) {
            stagedBytes -= assembly.decodedBytes
        }
    }

    private mutating func settle(_ route: WireRoute, id: String, ordinal: Int) {
        if let previous = settled[route], previous.ordinal > ordinal { return }
        settled[route] = Settled(logicalFrameId: id, ordinal: ordinal)
    }

    private mutating func releaseAndSettle(_ route: WireRoute, id: String, ordinal: Int) {
        if let active = assemblies[route], active.ordinal == ordinal, active.logicalFrameId == id {
            release(route)
        }
        settle(route, id: id, ordinal: ordinal)
    }

    private static func isLowercaseHex8(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
