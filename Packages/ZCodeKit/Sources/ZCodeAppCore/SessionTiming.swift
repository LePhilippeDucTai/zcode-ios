import Foundation
import ZCodeV4

/// Durée d'une carte d'outil (lot 13F), à partir des horodatages de l'hôte (ms).
public enum ToolTiming: Equatable, Sendable {
    /// Outil en cours depuis `since` : compteur rafraîchi chaque seconde par la vue.
    case running(since: Double)
    /// Durée figée `endedAt − startedAt`.
    case finished(milliseconds: Double)

    /// « 3,2 s », « 2 min 05 s »… ; en cours, mesurée jusqu'à `now`.
    public func label(now: Date) -> String {
        switch self {
        case .running(let since): TimeLabels.toolDuration(milliseconds: now.timeIntervalSince1970 * 1000 - since)
        case .finished(let milliseconds): TimeLabels.toolDuration(milliseconds: milliseconds)
        }
    }
}

extension ToolCall {
    /// Début et fin connus ⇒ durée figée, quel que soit le statut ; en cours avec un début ⇒ compteur ; sinon rien
    /// (approbation en attente, entrée en préparation, outil terminé sans `endedAt` : rien d'inventé).
    public var timing: ToolTiming? {
        guard let startedAt else { return nil }
        if let endedAt { return .finished(milliseconds: max(0, endedAt - startedAt)) }
        return status == .running ? .running(since: startedAt) : nil
    }

    /// Ligne de la carte dépliée : « Début 14:32:05 · Fin 14:33:10 », « Début 14:32:05 · en cours ».
    public func boundsLabel(_ labels: TimeLabels) -> String? {
        guard let startedAt else { return nil }
        let start = "Début \(labels.clock(startedAt))"
        if let endedAt { return "\(start) · Fin \(labels.clock(endedAt))" }
        return status == .running ? "\(start) · en cours" : start
    }
}

/// Temps de travail d'une session (lot 13F) : somme des `activeMs` des en-têtes de tour chargés (« temps de travail
/// faisant foi » de l'hôte) ; un tour en cours compte depuis son `startedAt` (son `activeMs` n'est pas à jour).
public struct SessionWorkTime: Equatable, Sendable {
    public static let empty = SessionWorkTime(rows: [], partial: false)

    /// Somme des tours qui ne sont pas en cours.
    public let completedMs: Double
    /// Débuts (ms) des tours en cours : le total défile.
    public let runningStarts: [Double]
    /// Historique plus ancien non chargé : total minoré, préfixé « ≥ ».
    public let partial: Bool
    /// Au moins un en-tête de tour chargé.
    public let hasTurns: Bool

    public init(rows: [ConversationRow], partial: Bool) {
        var completed = 0.0
        var running: [Double] = []
        var hasTurns = false
        for row in rows {
            guard case .turnHeader(let header) = row.content else { continue }
            hasTurns = true
            if header.state == .running {
                if let startedAt = header.startedAt { running.append(startedAt) }
            } else {
                completed += max(0, header.activeMs ?? 0)
            }
        }
        completedMs = completed
        runningStarts = running
        self.partial = partial
        self.hasTurns = hasTurns
    }

    public var isRunning: Bool { !runningStarts.isEmpty }

    public func totalMs(now: Date) -> Double {
        let nowMs = now.timeIntervalSince1970 * 1000
        return completedMs + runningStarts.reduce(0) { $0 + max(0, nowMs - $1) }
    }

    /// « 47 min de travail », « ≥ 9 s de travail » ; `nil` sans tour chargé.
    public func label(now: Date) -> String? {
        guard hasTurns else { return nil }
        return "\(partial ? "≥ " : "")\(TimeLabels.workDuration(milliseconds: totalMs(now: now))) de travail"
    }
}

/// Ligne d'en-tête de la conversation (lot 13F).
public enum SessionDurations {
    /// « 47 min de travail · créée il y a 3 h 12 » ; une partie inconnue est omise ; `nil` si les deux le sont.
    public static func line(work: SessionWorkTime, createdAt: Double?, now: Date, labels: TimeLabels) -> String? {
        let parts = [work.label(now: now), createdAt.map { labels.created($0, now: now) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « Créée le mardi 13 octobre, 11:52:41 ».
    public static func exactCreation(_ createdAt: Double, now: Date, labels: TimeLabels) -> String {
        "Créée le \(labels.exact(createdAt, now: now))"
    }
}
