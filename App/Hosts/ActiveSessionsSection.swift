import SwiftUI
import ZCodeAppCore

/// Section « Sessions en cours » de la fiche de l'hôte (lot 13J) : attentes de réponse puis tours en cours, tous projets.
struct ActiveSessionsSection: View {
    let host: Host
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            switch model.activeSessions(for: host) {
            case .loading:
                HStack(spacing: 8) { ProgressView(); Text("Recherche des sessions…").foregroundStyle(.secondary) }
            case .empty:
                Text("Aucune session en cours").foregroundStyle(.secondary)
            case .entries(let shown, let hiddenCount):
                ForEach(shown) { row($0) }
                if hiddenCount > 0 {
                    Text(ActiveSessions.hiddenLabel(hiddenCount)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            // Sur l'en-tête, pas sur la `Section` : elle transmettrait l'identifiant à chaque ligne.
            Text("Sessions en cours").accessibilityIdentifier("host-active-sessions")
        }
    }

    /// Ligne comme celle de la liste du projet (`SessionsView.row`), plus le nom du projet en légende.
    private func row(_ entry: ActiveSession) -> some View {
        let sessions = model.sessions(for: host, workspace: entry.workspace)
        let summary = entry.summary
        let title = summary.title.isEmpty ? SessionListLayout.untitledTitle : summary.title
        return NavigationLink(value: SessionRoute(hostId: host.id, workspace: entry.workspace, sessionId: summary.sessionId)) {
            SessionRowView(title: title, preview: summary.lastAssistantPreview, phase: summary.phase,
                           pendingCount: summary.pendingCount, date: summary.lastActivityDate,
                           unread: sessions.isUnread(summary),
                           workflow: WorkflowLabels.activity(summary.workflowActivity?.runs),
                           project: entry.projectName)
        }
        .accessibilityIdentifier("active-session-\(summary.sessionId)")
    }
}
