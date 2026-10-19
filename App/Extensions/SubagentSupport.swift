import SwiftUI
import ZCodeAppCore

/// Alerte « Action impossible » de `SubagentsModel.actionError`, partagée par la liste et le détail : seule la vue
/// visible la présente (la liste reste sous le détail poussé, les deux ne doivent jamais présenter en même temps).
private struct SubagentActionAlert: ViewModifier {
    let model: SubagentsModel
    let suppressed: Bool
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .alert("Action impossible", isPresented: Binding(
                get: { visible && !suppressed && model.actionError != nil },
                set: { if !$0 { model.dismissMessages() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }
}

extension View {
    /// `suppressed` : une feuille d'édition est ouverte au-dessus ; elle présente elle-même l'alerte, une seule à la fois.
    func subagentActionAlert(_ model: SubagentsModel, suppressed: Bool = false) -> some View {
        modifier(SubagentActionAlert(model: model, suppressed: suppressed))
    }
}

/// Bandeau rouge de la liste lue gardée en lecture seule après un échec de relecture : « Hors ligne » pour une panne de
/// connexion (`offline`), libellé neutre sinon (refus de l'hôte) ; `message` : la raison de l'échec, si on la détaille.
/// Partagé par les sous-agents et les plugins.
struct SubagentOfflineBanner: View {
    let offline: Bool
    var message: String?

    var body: some View {
        Label(ExtensionsLabels.readOnlyBanner(offline: offline), systemImage: offline ? "wifi.slash" : "exclamationmark.triangle")
            .foregroundStyle(.red)
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Avis de prise en compte différée, en pied de liste et de détail.
struct SubagentNoticeLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "clock")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("subagents-notice")
    }
}
