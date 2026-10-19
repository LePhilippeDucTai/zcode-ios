import SwiftUI
import ZCodeAppCore

/// Heure d'un message (lot 13F) : « il y a 12 min », rafraîchie chaque minute par sa propre horloge ; un toucher
/// bascule sur l'heure exacte, un second revient. Le choix est perdu quand la cellule quitte la liste.
struct MessageTimeLabel: View {
    let createdAt: Double
    @State private var exact = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(exact ? TimeLabels.current.exact(createdAt, now: context.date)
                       : TimeLabels.current.relative(createdAt, now: context.date))
                .font(ZCodeTypography.metadata)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { exact.toggle() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(exact ? "Afficher l'heure relative" : "Afficher l'heure exacte")
                .accessibilityIdentifier("message-time")
        }
    }
}

/// Ligne sous la barre : « 47 min de travail · créée il y a 3 h 12 ». Défile chaque seconde pendant un tour, chaque
/// minute sinon ; un toucher montre la date exacte de création (s'il y en a une). Masquée quand il n'y a rien à dire.
struct SessionDurationsBar: View {
    let work: SessionWorkTime
    let host: Host
    let workspace: String
    let sessionId: String
    /// La date de création est lue ici (et non dans `ChatView`) : seule la barre observe l'index des sessions.
    @Environment(AppModel.self) private var model
    @State private var exact = false

    var body: some View {
        let createdAt = model.sessionCreatedAt(host: host, workspace: workspace, sessionId: sessionId)
        TimelineView(.periodic(from: .now, by: work.isRunning ? 1 : 60)) { context in
            if let text = text(now: context.date, createdAt: createdAt) {
                Text(text)
                    .font(ZCodeTypography.metadata)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { if createdAt != nil { exact.toggle() } }
                    .accessibilityAddTraits(createdAt != nil ? .isButton : [])
                    .accessibilityHint(createdAt == nil ? "" : exact ? "Afficher les durées" : "Afficher la date de création")
                    .accessibilityIdentifier("session-durations")
                    .padding(.vertical, 2)
            }
        }
    }

    private func text(now: Date, createdAt: Double?) -> String? {
        if exact, let createdAt { return SessionDurations.exactCreation(createdAt, now: now, labels: .current) }
        return SessionDurations.line(work: work, createdAt: createdAt, now: now, labels: .current)
    }
}

/// Durée d'une carte d'outil (lot 13F) : figée une fois l'outil terminé ; en cours, compteur depuis le début donné par
/// l'hôte (juste même si la conversation est ouverte tard), rafraîchi chaque seconde par sa propre horloge.
struct ToolDurationLabel: View {
    let timing: ToolTiming

    var body: some View {
        switch timing {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in label(context.date) }
        case .finished:
            label(.now)
        }
    }

    private func label(_ now: Date) -> some View {
        Text(timing.label(now: now))
            .font(ZCodeTypography.toolStatus)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityIdentifier("tool-duration")
    }
}
