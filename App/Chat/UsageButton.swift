import SwiftUI
import ZCodeAppCore

/// Bouton de la barre de la conversation : jauge et restant de la fenêtre de 5 h ; ouvre l'utilisation en feuille.
struct UsageButton: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let usage = model.usage(for: host)
        Button { showing = true } label: {
            // Icône seule : avec le pourcentage en texte, iOS 26 rangeait le bouton dans le menu de débordement de la
            // barre. Le restant est lu par VoiceOver et détaillé dans la feuille.
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
        .accessibilityLabel(usage.fiveHoursRemaining.map { "Utilisation : \(Int($0.rounded())) % restants sur 5 heures" }
                            ?? "Utilisation")
        .accessibilityIdentifier("chat-usage")
        // Ouverture d'une conversation : quota relu s'il date de plus d'une minute (rappel du composeur).
        .task { await usage.loadIfNeeded(maxAge: 60) }
        .sheet(isPresented: $showing) { UsageSheet(host: host, isPresented: $showing) }
    }
}

/// Écran « Utilisation » de l'hôte, en feuille (barre de la conversation, puce du composeur).
struct UsageSheet: View {
    let host: Host
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            UsageView(host: host)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("OK") { isPresented = false } }
                }
        }
    }
}
