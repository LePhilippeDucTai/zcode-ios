import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Bandeau du Goal en haut de la conversation : titre, statut, itération, durée, Pause / Reprendre. Un toucher ouvre le
/// détail.
struct GoalBanner: View {
    let conversation: ConversationModel
    let goal: GoalState
    @State private var showingDetail = false

    var body: some View {
        let summary = GoalSummary(goal)
        HStack(spacing: 10) {
            Image(systemName: "target").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.callout.weight(.semibold)).lineLimit(1)
                if summary.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(subtitle(summary, at: context.date))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(subtitle(summary, at: .now)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("goal-status")
            .accessibilityValue(summary.statusLabel)
            Spacer(minLength: 4)
            GoalControl(conversation: conversation, goal: goal)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        // Conteneur : sans `.contain`, l'identifiant serait appliqué aux enfants et masquerait `goal-status` / `goal-pause`.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal-banner")
        .sheet(isPresented: $showingDetail) { GoalDetailView(conversation: conversation) }
    }

    private func subtitle(_ summary: GoalSummary, at date: Date) -> String {
        [summary.statusLabel, summary.iterationLabel, GoalSummary.durationLabel(summary.elapsedSeconds(at: date))]
            .compactMap(\.self).joined(separator: " · ")
    }
}

/// Pause / Reprendre selon `availability`, coche une fois le Goal atteint.
private struct GoalControl: View {
    let conversation: ConversationModel
    let goal: GoalState

    var body: some View {
        if conversation.canPauseGoal {
            Button("Mettre le Goal en pause", systemImage: "pause.circle.fill") { Task { await conversation.pauseGoal() } }
                .labelStyle(.iconOnly).font(.title2)
                .accessibilityIdentifier("goal-pause")
        } else if conversation.canResumeGoal {
            Button("Reprendre le Goal", systemImage: "play.circle.fill") { Task { await conversation.resumeGoal() } }
                .labelStyle(.iconOnly).font(.title2)
                .accessibilityIdentifier("goal-resume")
        } else if goal.status == .verified {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                .accessibilityLabel("Goal atteint")
        }
    }
}

/// Détail du Goal : objectif complet, itérations avec leurs tâches, vérifications avec leur raison.
struct GoalDetailView: View {
    let conversation: ConversationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let goal = conversation.goal {
                    content(GoalSummary(goal), goal: goal)
                } else {
                    ContentUnavailableView("Aucun Goal", systemImage: "target")
                }
            }
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                if let goal = conversation.goal {
                    ToolbarItem(placement: .primaryAction) { GoalControl(conversation: conversation, goal: goal) }
                }
            }
        }
        .accessibilityIdentifier("goal-detail")
    }

    private func content(_ summary: GoalSummary, goal: GoalState) -> some View {
        List {
            Section("Objectif") {
                Text(summary.objective).textSelection(.enabled)
                LabeledContent("Statut", value: summary.statusLabel)
            }
            Section("Itérations") {
                ForEach(summary.iterations) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(row.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).fontWeight(row.isCurrent ? .semibold : .regular)
                            if row.todosTotal > 0 {
                                Text("\(row.todosDone)/\(row.todosTotal) tâches").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if row.isCurrent { ProgressView().controlSize(.small) }
                    }
                }
            }
            if !summary.verifications.isEmpty {
                Section("Vérifications") {
                    ForEach(summary.verificationEntries) { entry in
                        let verification = entry.verification
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Itération \(verification.iteration) · \(Self.outcome(verification.outcome))").font(.callout.weight(.medium))
                            if let reason = verification.reason, !reason.isEmpty {
                                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let next = verification.nextAction, !next.isEmpty {
                                Text("Ensuite : \(next)").font(.caption)
                            }
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Ce Goal continue jusqu'à ce qu'il soit atteint ou mis en pause. Pour changer d'objectif, lance un nouveau /goal.")
            }
        }
    }

    private static func outcome(_ outcome: GoalOutcome) -> String {
        switch outcome {
        case .pass: "Goal atteint"
        case .notSatisfied: "Non atteint, l'agent continue"
        case .failed: "Vérification impossible"
        default: outcome.rawValue
        }
    }
}
