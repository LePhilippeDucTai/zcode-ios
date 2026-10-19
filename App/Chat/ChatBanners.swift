import SwiftUI
import ZCodeAppCore

struct ChatBanners: View {
    let conversation: ConversationModel
    /// Fil d'un sous-agent : seuls l'échec de chargement et l'erreur de l'hôte restent.
    var readOnly = false
    let openWeb: () -> Void

    private var isFailed: Bool {
        if case .failed = conversation.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 6) {
            if let date = conversation.offlineCopyDate {
                // Copie hors ligne : le bandeau gris remplace le rouge « hôte injoignable ».
                OfflineBanner(savedAt: date, connecting: !isFailed) {
                    Task { await conversation.refresh() }
                }
            } else if case .failed(let reason) = conversation.phase {
                Banner(text: reason, systemImage: "wifi.exclamationmark", tint: .red) {
                    Button("Réessayer") { Task { await conversation.refresh() } }
                }
            }
            if let error = conversation.snapshot?.control?.lastError {
                Banner(text: error.message, systemImage: "exclamationmark.triangle", tint: .orange) { EmptyView() }
            }
            if !readOnly, let error = conversation.commandError {
                Banner(text: error, systemImage: "exclamationmark.bubble", tint: .red) {
                    Button("OK") { conversation.dismissCommandError() }
                }
            }
            if !readOnly, let notice = conversation.commandNotice {
                Banner(text: notice, systemImage: "info.circle", tint: .blue) {
                    Button("OK") { conversation.dismissCommandNotice() }
                }
            }
            if !readOnly, conversation.unconfirmedCount > 0 {
                Banner(text: "Envoi en cours de vérification auprès de l'hôte… Le message sera renvoyé si besoin.",
                       systemImage: "arrow.triangle.2.circlepath", tint: .orange) { EmptyView() }
            }
            if !readOnly, conversation.unsupportedInteractionCount > 0 {
                // Revue des hooks de l'espace de travail, ou demande que cette version de l'app ne sait pas lire.
                Banner(text: "L'agent attend une réponse à donner dans l'interface web.", systemImage: "hand.raised", tint: .orange) {
                    Button("Répondre", action: openWeb)
                }
            }
        }
        .padding(.horizontal)
    }
}

struct Banner<Actions: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            actions().font(.callout.bold())
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Bandeau d'une copie hors ligne (conversation ou liste des sessions).
struct OfflineBanner: View {
    let savedAt: Date
    let connecting: Bool
    let retry: () -> Void

    var body: some View {
        Banner(text: OfflineLabels.banner(savedAt: savedAt, connecting: connecting),
               systemImage: "wifi.slash", tint: .gray) {
            Button("Réessayer", action: retry)
                .accessibilityIdentifier("offline-retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-banner")
    }
}
