import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Ouverture du fil d'un sous-agent, fournie par l'écran de la conversation (les cellules n'ont pas le modèle).
/// Toujours égale à elle-même, comme `MessageForkAction` : les cellules restent comparées sur leurs seules données.
struct SubagentOpenAction: Sendable, Equatable {
    var open: (@MainActor @Sendable (SubagentContext) -> Void)?

    static func == (lhs: SubagentOpenAction, rhs: SubagentOpenAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var openSubagent = SubagentOpenAction()
}

/// « Voir le fil » sous la ligne compacte d'une carte Agent dont le sous-agent a une session.
struct SubagentOpenButton: View {
    let link: SubagentLink
    let childSessionId: String
    @Environment(\.openSubagent) private var openSubagent

    var body: some View {
        Button {
            openSubagent.open?(SubagentContext(sessionId: childSessionId, title: link.title, subagentType: link.subagentType))
        } label: {
            Label("Voir le fil", systemImage: "chevron.right.circle")
                .font(ZCodeTypography.metadata)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("Voir le fil du sous-agent \(link.title)")
        .accessibilityIdentifier("subagent-open")
    }
}

/// Puce « 2 sous-agents » sous la barre ; toucher → liste des sous-agents en cours (lot 13D). La feuille est tenue par
/// l'écran de la conversation : la puce disparaît avec le dernier sous-agent, la feuille ouverte doit rester.
struct RunningSubagentsChip: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        if let label = SubagentLabels.runningCount(count) {
            Button(action: show) {
                Label(label, systemImage: "person.2.fill")
                    .font(ZCodeTypography.metadata)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("running-subagents")
        }
    }
}

/// Feuille « Sous-agents en cours » ; vide (tous terminés pendant qu'elle est ouverte) : « Aucun sous-agent en cours ».
struct RunningSubagentsSheet: View {
    let subagents: [RunningSubagent]
    let open: (SubagentContext) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if subagents.isEmpty {
                    ContentUnavailableView("Aucun sous-agent en cours", systemImage: "person.2")
                } else {
                    List(subagents) { subagent in
                        Button { select(subagent) } label: {
                            RunningSubagentRow(subagent: subagent)
                        }
                        .accessibilityIdentifier("running-subagent-\(subagent.childSessionId)")
                    }
                }
            }
            .navigationTitle("Sous-agents en cours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Ferme la feuille puis pousse le fil : une poussée pendant la présentation de la feuille serait perdue.
    private func select(_ subagent: RunningSubagent) {
        let context = SubagentContext(sessionId: subagent.childSessionId,
                                      title: subagent.title.isEmpty ? subagent.subagentType : subagent.title,
                                      subagentType: subagent.subagentType)
        dismiss()
        let open = open
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            open(context)
        }
    }
}

private struct RunningSubagentRow: View {
    let subagent: RunningSubagent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(subagent.title.isEmpty ? subagent.subagentType : subagent.title).font(.body).lineLimit(1)
                Spacer()
                if let startedAt = subagent.startedAt {
                    ToolDurationLabel(timing: .running(since: startedAt))
                }
            }
            Text([subagent.subagentType, SubagentLabels.runningStatus(subagent.status)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(ZCodeTypography.metadata).foregroundStyle(.secondary)
            if let summary = subagent.summary, !summary.isEmpty {
                Text(summary).font(ZCodeTypography.metadata).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .foregroundStyle(.primary)
    }
}
