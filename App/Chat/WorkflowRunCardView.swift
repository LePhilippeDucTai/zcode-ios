import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Carte d'un run de workflow dans la conversation : état, phases et agents, jetons, questions, résultat ou erreur.
struct WorkflowRunCardView: View {
    let card: WorkflowRunCard
    let stop: (String) -> Void
    @Environment(\.openSubagent) private var openSubagent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(card.phases) { phase in
                VStack(alignment: .leading, spacing: 4) {
                    Text(phase.name)
                        .font(phase.isCurrent ? ZCodeTypography.metadata.bold() : ZCodeTypography.metadata)
                        .foregroundStyle(phase.isCurrent ? .primary : .secondary)
                    if !phase.agents.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(phase.agents) { agent in chip(agent) }
                            }
                        }
                    }
                }
            }
            if let tokens = card.spentTokens {
                Text("\(tokens.formatted(.number.locale(Locale(identifier: "fr_FR")))) jetons")
                    .font(ZCodeTypography.metadata).foregroundStyle(.secondary)
            }
            ForEach(card.questions, id: \.qid) { question in
                let who = question.actorName.map { "\($0) : " } ?? ""
                Label("\(who)\(question.question)", systemImage: "questionmark.bubble")
                    .font(.callout)
            }
            if let error = card.error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if let result = card.resultPreview, !result.isEmpty {
                Text(result).font(ZCodeTypography.monoCaption).lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        // Conteneur : l'identifiant reste sur la carte sans masquer `workflow-run-stop` ni les pastilles.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow \(card.name), \(card.statusLabel)\(card.summary.isEmpty ? "" : ", \(card.summary)")")
        .accessibilityIdentifier("workflow-run-card")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text([card.statusLabel, card.summary].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(ZCodeTypography.metadata).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if card.canStop {
                Button("Arrêter", role: .destructive) { stop(card.runId) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("workflow-run-stop")
            }
        }
    }

    @ViewBuilder
    private func chip(_ agent: WorkflowRunCard.Agent) -> some View {
        let label = Label(agent.name, systemImage: "circle.fill")
            .font(ZCodeTypography.metadata)
            .foregroundStyle(agentColor(agent.status))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(agentColor(agent.status).opacity(0.15), in: Capsule())
        if let sessionId = agent.sessionId {
            Button {
                openSubagent.open?(SubagentContext(sessionId: sessionId, title: agent.name, subagentType: ""))
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent \(agent.name), \(WorkflowLabels.actorStatus(agent.status))")
                .accessibilityIdentifier("workflow-run-agent-\(agent.id)")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agent \(agent.name), \(WorkflowLabels.actorStatus(agent.status))")
                .accessibilityIdentifier("workflow-run-agent-\(agent.id)")
        }
    }

    private var icon: String {
        switch card.status {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .errored: "xmark.octagon.fill"
        case .stopped: "stop.circle.fill"
        default: "clock"
        }
    }

    private var color: Color {
        switch card.status {
        case .running: .blue
        case .completed: .green
        case .errored: .red
        default: .secondary
        }
    }

    private func agentColor(_ status: WorkflowActorStatus) -> Color {
        switch status {
        case .running: .blue
        case .completed: .green
        default: .secondary
        }
    }
}
