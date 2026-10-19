import SwiftUI
import ZCodeAppCore
import ZCodeV4

struct SessionRowView: View {
    let title: String
    let preview: String?
    let phase: SessionPhase
    let pendingCount: Int
    let date: Date?
    let unread: Bool
    var pinned = false
    /// Mention du dernier run de workflow (`WorkflowLabels.activity`).
    var workflow: String?
    /// Nom du projet en légende (section « Sessions en cours » de la fiche de l'hôte).
    var project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if unread {
                    Circle()
                        .fill(.blue)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel("Non lu")
                        .accessibilityIdentifier("session-unread")
                }
                Text(title).font(unread ? .headline.weight(.heavy) : .headline).lineLimit(1)
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Épinglée")
                }
                Spacer()
                if let date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(unread ? .blue : .secondary)
                }
            }
            if let project {
                Label(project, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
            }
            if let preview, !preview.isEmpty {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if let workflow {
                Label(workflow, systemImage: "flowchart").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label(phase.label, systemImage: phase.isBusy ? "bolt.fill" : "circle.fill")
                    .font(.caption)
                    .foregroundStyle(phase.isBusy ? .blue : .secondary)
                if pendingCount > 0 {
                    Text(pendingCount == 1 ? "1 réponse attendue" : "\(pendingCount) réponses attendues")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
