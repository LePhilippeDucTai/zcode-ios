import Foundation
import ZCodeV4

/// Ce qu'affichent le bandeau et le détail du Goal (règles de la section « Goal » de l'interface web).
public struct GoalSummary: Equatable, Sendable {
    /// Itération du Goal : titre, tâches faites / total, itération en cours.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let todosDone: Int
        public let todosTotal: Int
        public let isCurrent: Bool
    }

    /// Prochaine action de repli de ZCode, sans intérêt comme titre.
    static let fallbackNextAction = "Continue verifying and completing the goal."
    static let maxTitleLength = 80

    public let objective: String
    public let title: String
    public let statusLabel: String
    /// Le travail ou la vérification avancent : la durée défile.
    public let isRunning: Bool
    public let iterationLabel: String?
    public let iterations: [Row]
    /// Plus récente d'abord.
    public let verifications: [GoalVerification]
    /// Les mêmes, identifiées pour une liste : une itération peut porter deux conclusions (échec du vérificateur puis
    /// validation par défaut).
    public var verificationEntries: [VerificationEntry] {
        verifications.enumerated().map { VerificationEntry(id: $0.offset, verification: $0.element) }
    }

    public struct VerificationEntry: Equatable, Sendable, Identifiable {
        public let id: Int
        public let verification: GoalVerification
    }
    private let timeUsedSeconds: Int
    private let activeRunStartedAtMs: Double?

    public init(_ goal: GoalState) {
        objective = goal.objective
        let firstLine = (goal.summaryTitle ?? goal.objective).split(separator: "\n", omittingEmptySubsequences: true).first
        title = String((firstLine ?? "").prefix(Self.maxTitleLength))
        statusLabel = Self.label(goal.status)
        isRunning = goal.status == .active || goal.status == .verifying
        verifications = goal.verifications.sorted { $0.iteration > $1.iteration }
        timeUsedSeconds = goal.timeUsedSeconds
        activeRunStartedAtMs = goal.activeRunStartedAtMs
        iterations = Self.rows(goal, firstTitle: title)
        // Itération en cours (dernière ligne) : `goal.iteration` vaut 0 pendant la 1re course et ne compte la suivante
        // qu'à sa vérification.
        iterationLabel = iterations.last.map { "Itération \($0.id)" }
    }

    /// Temps de travail cumulé, plus la course en cours ; jamais négatif (horloges de l'hôte et de l'iPhone décalées).
    public func elapsedSeconds(at now: Date) -> Int {
        guard let started = activeRunStartedAtMs else { return timeUsedSeconds }
        return timeUsedSeconds + max(0, Int((now.timeIntervalSince1970 * 1000 - started) / 1000))
    }

    /// « 42 s », « 3 min 05 s », « 1 h 02 min ».
    public static func durationLabel(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3_600 { return "\(seconds / 60) min " + String(format: "%02d s", seconds % 60) }
        return "\(seconds / 3_600) h " + String(format: "%02d min", (seconds % 3_600) / 60)
    }

    static func label(_ status: GoalStatus) -> String {
        switch status {
        case .active: "En cours"
        case .verifying: "Vérification…"
        case .notSatisfied: "Non atteint, l'agent continue"
        case .paused: "En pause"
        case .verified: "Atteint"
        case .failed: "Vérification impossible"
        default: status.rawValue
        }
    }

    /// Lignes 1…N : N couvre l'itération courante, les tâches projetées et la continuation ouverte par une vérification
    /// non satisfaite.
    private static func rows(_ goal: GoalState, firstTitle: String) -> [Row] {
        let last = goal.verifications.max { $0.iteration < $1.iteration }
        let continuation = last.map { $0.outcome == .notSatisfied ? $0.iteration + 1 : $0.iteration } ?? 0
        let count = max(goal.iteration, goal.iterations.map(\.iteration).max() ?? 0, continuation, 1)
        // Ligne « en cours » seulement si quelque chose tourne (pas en pause, ni une fois atteint).
        let working = [GoalStatus.active, .verifying, .notSatisfied].contains(goal.status)
        return (1...count).map { number in
            let items = goal.iterations.first { $0.iteration == number }?.items ?? []
            return Row(id: number, title: title(of: number, goal, firstTitle: firstTitle),
                       todosDone: items.count { $0.isCompleted }, todosTotal: items.count,
                       isCurrent: number == count && working)
        }
    }

    private static func title(of number: Int, _ goal: GoalState, firstTitle: String) -> String {
        if number == 1 { return firstTitle }
        let next = goal.verifications.last { $0.iteration == number - 1 }?.nextAction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return next.isEmpty || next == fallbackNextAction ? "Itération \(number)" : next
    }
}
