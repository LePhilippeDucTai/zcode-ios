import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Messages en attente au-dessus du composeur.
struct QueuePanel: View {
    let conversation: ConversationModel

    var body: some View {
        let items = conversation.queuedItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if conversation.queuePaused {
                    HStack {
                        Text(ChatLabels.queuePause(reason: conversation.snapshot?.queue?.pauseReason))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Continuer") { Task { await conversation.resumeQueue() } }.font(.caption.bold())
                    }
                }
                ForEach(items, id: \.queueItemId) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(item.kind == "compact" ? "/compact" : item.text).font(.callout).lineLimit(2)
                        Spacer()
                        if !item.isLocked {
                            if conversation.canSendQueuedNow {
                                Button { Task { await conversation.sendQueuedNow(item.queueItemId) } } label: {
                                    Image(systemName: "arrow.turn.down.right")
                                }
                                .accessibilityLabel("Guider maintenant")
                            }
                            Button(role: .destructive) { Task { await conversation.deleteQueued(item.queueItemId) } } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Retirer de la file")
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}

/// Message qui guidera le tour en cours, affiché en fin de conversation.
struct PendingGuideBubble: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            UserBubble(text: text).opacity(0.6)
            Text("En attente pour guider l'agent…").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
