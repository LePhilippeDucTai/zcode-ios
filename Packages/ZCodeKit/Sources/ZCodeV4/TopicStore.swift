import Foundation
import ZCodeWire

/// Action que le propriétaire du store doit exécuter.
public enum TopicEffect: Equatable, Sendable {
    /// Appeler `resync…V4{subscriptionId, base, forceSnapshot}`, puis `resyncAcknowledged` ou `resyncFailed`.
    case resync(subscriptionId: String, base: Watermark?, forceSnapshot: Bool)
    /// La reprise a échoué : se réabonner de zéro (`subscribe…V4` puis `subscribed`).
    case resubscribe
    /// Contenu illisible pour ce client (ZCode plus récent ?) : le redemander donnerait le même résultat.
    case contentRejected(String)
}

/// Application des trames d'un sujet selon les règles seq/resync (§3.3 de `10-protocol-spec.md`).
///
/// Valeur pure, sans E/S : chaque entrée renvoie les effets à exécuter. Une seule resync à la fois ;
/// les trames reçues avant l'accusé d'abonnement sont mises en attente (l'accusé et la trame initiale
/// n'arrivent pas toujours dans cet ordre côté client).
public struct TopicStore<Projection: TopicProjection>: Sendable {
    private struct Recovery: Sendable {
        var forceSnapshot: Bool
        var ackMode: AckMode?
        var frameSeen = false
        /// Trou en direct apparu après la trame de reprise, avant l'accusé : relancer une resync à la clôture.
        var successorNeeded = false
    }

    /// Trames gardées en attente de l'accusé d'abonnement.
    public static var maxStagedFrames: Int { 64 }

    public let topic: String
    public private(set) var projection: Projection?
    public private(set) var subscriptionId: String?
    public private(set) var seq = 0
    private var hasBase = false
    private var awaitingInitial = false
    private var staged: [LogicalFrame] = []
    private var stagedOverflow = false
    private var recovery: Recovery?

    public init(topic: String) {
        self.topic = topic
    }

    /// Position confirmée (à renvoyer comme `base`) ; `nil` tant qu'aucun état cohérent n'est détenu.
    public var watermark: Watermark? {
        guard hasBase, let projection else { return nil }
        return Watermark(logEpoch: projection.logEpoch, seq: seq)
    }

    public var isRecovering: Bool { recovery != nil }

    /// Abonné, en attente du snapshot initial (aucune base valable) : à borner dans le temps.
    public var isAwaitingInitial: Bool { subscriptionId != nil && awaitingInitial && !hasBase }

    /// Un nouvel abonnement va être demandé : les trames de l'ancien sont désormais ignorées et celles qui
    /// arrivent avant le nouvel accusé sont mises en attente (l'accusé peut arriver après la trame initiale).
    public mutating func resubscribing() {
        subscriptionId = nil
        staged = []
        stagedOverflow = false
        recovery = nil
    }

    /// Le snapshot initial n'est pas arrivé à temps : le redemander explicitement.
    public mutating func initialTimedOut() -> [TopicEffect] {
        guard isAwaitingInitial, recovery == nil else { return [] }
        return requestResync(force: true)
    }

    /// Accusé de `subscribe…V4` (premier abonnement ou réabonnement).
    public mutating func subscribed(_ ack: SubscribeAck) -> [TopicEffect] {
        subscriptionId = ack.subscriptionId
        recovery = nil
        if ack.mode != .resume || ack.logEpoch != projection?.logEpoch {
            hasBase = false
            awaitingInitial = true
        }
        let pending = staged
        staged = []
        if stagedOverflow {
            stagedOverflow = false
            return requestResync(force: true)
        }
        if ack.mode == .resume, !hasBase {
            // « resume » sans état local : seuls des deltas suivraient, inapplicables. Exiger un snapshot.
            return requestResync(force: true)
        }
        var effects: [TopicEffect] = []
        for frame in pending where frame.route.subscriptionId == ack.subscriptionId {
            effects += receive(frame)
        }
        return effects
    }

    public mutating func receive(_ frame: LogicalFrame) -> [TopicEffect] {
        guard let subscriptionId else {
            if staged.count < Self.maxStagedFrames {
                staged.append(frame)
            } else {
                stagedOverflow = true
            }
            return []
        }
        // ① Autre génération d'abonnement ou autre sujet : ignorée.
        guard frame.route.subscriptionId == subscriptionId, frame.route.topic == topic else { return [] }
        guard let decoded = try? TopicFrame(json: frame.frame) else { return requestResync(force: true) }
        let isRecovery = frame.deliveryKind == .recovery

        switch decoded.payload {
        case .unknown(let kind):
            return [.contentRejected("type de trame inconnu : \(kind)")]
        case .snapshot(let json):
            // ② Remplacement complet, jamais de fusion.
            do {
                projection = try Projection(json: json)
            } catch {
                return [.contentRejected("snapshot illisible (\(error))")]
            }
            seq = decoded.toSeq
            hasBase = true
            awaitingInitial = false
            if isRecovery { markRecoveryFrameSeen() }
            return []
        case .deltas(let items):
            guard hasBase, projection != nil else {
                // Pas de base : on attend le snapshot initial, sinon on le redemande.
                return awaitingInitial ? [] : requestResync(force: true)
            }
            // ③ Doublon ou trame déjà couverte.
            if decoded.toSeq <= seq {
                if isRecovery { markRecoveryFrameSeen() }
                return []
            }
            // Pendant une reprise, les trames en direct sont couvertes par la trame de reprise à venir.
            if frame.deliveryKind == .online, let recovery, !recovery.frameSeen { return [] }
            // ④ Trou : une seule resync ; une reprise `resume` qui présente encore un trou force un snapshot.
            guard decoded.fromSeq == seq else {
                if !isRecovery, var current = recovery, current.frameSeen {
                    // Reprise déjà appliquée, accusé attendu : la resync suivante partira à sa clôture (§3.3).
                    current.successorNeeded = true
                    recovery = current
                    return []
                }
                return requestResync(force: isRecovery && recovery?.ackMode == .resume)
            }
            projection?.apply(items.map(Projection.decodeDelta))
            seq = decoded.toSeq
            if isRecovery { markRecoveryFrameSeen() }
            return []
        }
    }

    /// Accusé de `resync…V4`.
    public mutating func resyncAcknowledged(_ ack: SubscribeAck) -> [TopicEffect] {
        guard ack.subscriptionId == subscriptionId, var current = recovery else { return [] }
        current.ackMode = ack.mode
        if current.frameSeen {
            // La trame de reprise est déjà appliquée : la base qu'elle a établie reste valable.
            recovery = nil
            return current.successorNeeded ? requestResync(force: false) : []
        }
        if ack.mode != .resume {
            hasBase = false
            awaitingInitial = true
        }
        recovery = current
        return []
    }

    /// L'appel `resync…V4` a échoué.
    public mutating func resyncFailed() -> [TopicEffect] {
        guard recovery != nil else { return [] }
        recovery = nil
        return [.resubscribe]
    }

    /// Faute du réassembleur pour une trame de ce sujet.
    public mutating func assemblyFault(_ fault: WireFault) -> [TopicEffect] {
        guard fault.route.topic == topic else { return [] }
        guard let subscriptionId else {
            stagedOverflow = true             // la trame perdue sera redemandée dès l'accusé
            return []
        }
        guard fault.route.subscriptionId == subscriptionId else { return [] }
        if fault.reasonCode == WireFault.Reason.wireVersionUnsupported {
            return [.contentRejected("format de trame non pris en charge (\(fault.reasonCode))")]
        }
        return requestResync(force: !hasBase)
    }

    /// Aucune trame de reprise reçue 30 s après la demande : forcer un snapshot, puis se réabonner.
    public mutating func recoveryTimedOut() -> [TopicEffect] {
        guard let current = recovery, let subscriptionId else { return [] }
        if !current.forceSnapshot {
            recovery = Recovery(forceSnapshot: true)
            return [.resync(subscriptionId: subscriptionId, base: watermark, forceSnapshot: true)]
        }
        recovery = nil
        return [.resubscribe]
    }

    // MARK: - Interne

    private mutating func requestResync(force: Bool) -> [TopicEffect] {
        guard let subscriptionId else { return [] }
        if var current = recovery {
            guard force, !current.forceSnapshot else { return [] }
            current.forceSnapshot = true
            current.ackMode = nil
            current.frameSeen = false
            recovery = current
            return [.resync(subscriptionId: subscriptionId, base: watermark, forceSnapshot: true)]
        }
        recovery = Recovery(forceSnapshot: force)
        return [.resync(subscriptionId: subscriptionId, base: watermark, forceSnapshot: force)]
    }

    private mutating func markRecoveryFrameSeen() {
        guard var current = recovery else { return }
        current.frameSeen = true
        recovery = current.ackMode == nil ? current : nil
    }
}

public typealias ConversationStore = TopicStore<ConversationSnapshot>
public typealias SessionsIndexStore = TopicStore<SessionsIndex>

extension TopicStore where Projection == ConversationSnapshot {
    /// Ajoute une page d'historique à la fenêtre. Renvoie `false` (page jetée) si elle a été calculée dans
    /// une autre époque du journal : les `rowId` n'y ont plus le même sens.
    @discardableResult
    public mutating func mergeOlderRows(_ page: RowsRangePage) -> Bool {
        guard var current = projection, page.atLogEpoch == current.logEpoch else { return false }
        current.insertOlderRows(page.rows)
        projection = current
        return true
    }
}
