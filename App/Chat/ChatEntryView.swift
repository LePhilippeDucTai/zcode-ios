import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Une cellule de la conversation ; `Equatable` pour que seule l'entrée modifiée soit réévaluée pendant le streaming.
struct ChatEntryView: View, Equatable {
    let entry: ChatEntry
    /// Dernière réponse que l'hôte permet de relancer : bouton « Relancer » dessous.
    var canRetry = false
    /// Réponse que l'hôte permet de prendre comme point de départ (« Repartir d'ici »).
    var canFork = false
    /// Ouvre les fichiers modifiés d'un tour ; hors de l'égalité (seules les données décident de redessiner la cellule).
    var openChanges: (RowTarget) -> Void = { _ in }
    var retry: () -> Void = {}
    /// Arrête un run de workflow (hors de l'égalité, comme `openChanges`).
    var stopWorkflowRun: (String) -> Void = { _ in }
    /// Plie ou déplie un groupe de cartes d'outils (hors de l'égalité).
    var toggleToolGroup: (Int) -> Void = { _ in }

    nonisolated static func == (lhs: ChatEntryView, rhs: ChatEntryView) -> Bool {
        lhs.entry == rhs.entry && lhs.canRetry == rhs.canRetry && lhs.canFork == rhs.canFork
    }

    var body: some View {
        switch entry.content {
        case .item(let item):
            VStack(alignment: .leading, spacing: 6) {
                ChatItemView(item: item, canFork: canFork)
                if let time = entry.messageTime {
                    // Sous la bulle (à droite) pour une question, sous la réponse (à gauche) sinon.
                    MessageTimeLabel(createdAt: time)
                        .frame(maxWidth: .infinity, alignment: item.isUserMessage ? .trailing : .leading)
                }
                if canRetry {
                    Button("Relancer", systemImage: "arrow.clockwise", action: retry)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("chat-retry")
                }
            }
        case .workflowRun(let card):
            // Ni copie, ni « Repartir d'ici », ni menu contextuel de message : ce n'est pas un message.
            WorkflowRunCardView(card: card, stop: stopWorkflowRun)
        case .toolGroup(let group):
            ToolGroupRow(group: group) { toggleToolGroup(group.id) }
        case .turnFooter(let header):
            if let summary = header.summaryLabel {
                HStack(spacing: 4) {
                    Text(summary)
                    if let files = header.fileChangesLabel {
                        if let target = entry.fileChangesTarget {
                            Button { openChanges(target) } label: { Text("· \(files)").underline() }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("turn-changes-\(target.rowId)")
                        } else {
                            Text("· \(files)")
                        }
                    }
                }
                .font(ZCodeTypography.metadata)
                .foregroundStyle(header.state == .failed ? .red : .secondary)
            }
        }
    }
}

private extension ChatItem {
    var isUserMessage: Bool { if case .user = self { true } else { false } }
}
