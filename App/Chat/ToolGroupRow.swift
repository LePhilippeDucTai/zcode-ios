import SwiftUI
import ZCodeAppCore

/// Ligne de regroupement de cartes d'outils (lot 13I) : résumé replié, ou « Réduire » une fois dépliée.
/// Les cartes du groupe suivent dans la liste quand il est déplié.
struct ToolGroupRow: View {
    let group: ToolGroup
    let toggle: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: group.isExpanded ? "chevron.up" : "square.stack.3d.up")
                    .font(ZCodeTypography.toolIcon)
                    .foregroundStyle(.secondary)
                if group.isExpanded {
                    // Interpolation plutôt que `Text + Text` (déprécié en iOS 26).
                    Text("Réduire \(Text(group.summary).font(ZCodeTypography.toolSummary).foregroundStyle(.secondary))")
                        .font(ZCodeTypography.toolName)
                        .lineLimit(1)
                } else {
                    Text(group.summary).font(ZCodeTypography.toolName).lineLimit(1)
                }
                Spacer(minLength: 4)
                duration
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(group.isExpanded ? "Réduire, \(group.summary)" : group.summary)
        .accessibilityValue(group.isExpanded ? "déplié" : "replié")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tool-group-\(group.id)")
    }

    @ViewBuilder private var duration: some View {
        if group.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in durationText(context.date) }
        } else {
            durationText(.now)
        }
    }

    @ViewBuilder private func durationText(_ now: Date) -> some View {
        if let milliseconds = group.durationMs(now: now) {
            Text(TimeLabels.toolDuration(milliseconds: milliseconds))
                .font(ZCodeTypography.toolStatus)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
