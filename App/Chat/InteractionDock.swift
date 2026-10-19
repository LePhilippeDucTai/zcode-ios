import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Demande de l'agent (autorisation ou question), à la place du composeur tant qu'elle attend une réponse.
struct InteractionDock: View {
    let conversation: ConversationModel
    let interaction: PendingInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Hauteur bornée : une longue question ou un long plan défile dans le dock, la conversation reste visible.
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(interaction.interactionId)               // nouvelle demande : formulaire vierge
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.4)))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .disabled(conversation.respondingInteractionId == interaction.interactionId)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("interaction-dock")
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(title).font(.callout.bold())
            Spacer()
            if conversation.respondingInteractionId == interaction.interactionId {
                ProgressView().controlSize(.small)
            } else if conversation.queuedInteractionCount > 0 {
                Text("+\(conversation.queuedInteractionCount)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    .accessibilityLabel("\(conversation.queuedInteractionCount) autres demandes en attente")
            }
        }
        if let origin = ChatLabels.origin(interaction.origin) {
            Label(origin, systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
        }
        if let auto = interaction.autoResolution, !auto.isSnoozed {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let seconds = auto.countdownSeconds(now: context.date) {
                    Button(ChatLabels.countdown(seconds: seconds)) { pause() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .accessibilityHint("Touche pour que l'agent attende ta réponse")
                }
            }
        }
    }

    private var title: String {
        switch interaction.payload {
        case .permission(let request): "Autoriser \(request.toolName) ?"
        case .userInput(let request) where request.isPlanApproval: "Plan à valider"
        case .userInput: "L'agent te pose une question"
        case .unsupported: "Demande de l'agent"
        }
    }

    @ViewBuilder private var content: some View {
        switch interaction.payload {
        case .permission(let request):
            PermissionCard(prompt: PermissionPrompt(request), respond: respond)
        case .userInput(let request) where request.isPlanApproval:
            PlanApprovalCard(request: request, respond: respond)
        case .userInput(let request) where !(request.questions ?? []).isEmpty:
            QuestionsCard(questions: request.questions ?? [], respond: respond, touched: pause)
        case .userInput(let request):
            SimpleInputCard(request: request, respond: respond)
        case .unsupported:
            EmptyView()                                          // jamais courante : voir `currentInteraction`
        }
    }

    private func respond(_ answer: InteractionAnswer) {
        Task { await conversation.respond(to: interaction, with: answer) }
    }

    private func pause() {
        Task { await conversation.pauseAutoResolution(of: interaction) }
    }
}
