import SwiftUI
import ZCodeAppCore

/// Conversations archivées d'un projet : désarchivage, suppression définitive immédiate, et date de suppression
/// automatique (30 jours après l'archivage).
struct ArchivedSessionsView: View {
    let host: Host
    let workspace: String
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var actionError: String?
    @State private var deleteTarget: ArchivedSession?

    var body: some View {
        let sessions = model.sessions(for: host, workspace: workspace)
        NavigationStack {
            List {
                if case .failed(let reason) = sessions.archivedPhase {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                ForEach(sessions.archived) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title.isEmpty ? "Sans titre" : session.title)
                            .font(.body.weight(.medium))
                        if let deletionDate = session.archivedAt?.addingTimeInterval(SessionsModel.archiveRetention) {
                            Text("Supprimée définitivement le \(deletionDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("archived-\(session.sessionId)")
                    .swipeActions {
                        Button("Supprimer définitivement", role: .destructive) { deleteTarget = session }
                            .accessibilityIdentifier("archived-delete-\(session.sessionId)")
                        Button("Désarchiver") { Task { await restore(session) } }
                            .accessibilityIdentifier("archived-restore-\(session.sessionId)")
                    }
                }
                if sessions.archived.isEmpty, sessions.archivedPhase == .ready {
                    ContentUnavailableView("Aucune conversation archivée", systemImage: "archivebox")
                }
                Section {
                    Text("Une conversation archivée disparaît de toutes les listes (ici et dans l'interface web) et est "
                         + "supprimée définitivement au bout de 30 jours. Son contenu reste dans la base de l'hôte, "
                         + "qui ne propose pas d'effacement.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("archived-sessions-list")
            .navigationTitle("Sessions archivées")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await sessions.refreshArchived() }
            .refreshable { await sessions.refreshArchived() }
            .confirmationDialog("Supprimer définitivement cette conversation ?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ), titleVisibility: .visible) {
                Button("Supprimer définitivement", role: .destructive) {
                    Task { await deleteNow(deleteTarget?.sessionId) }
                }
            } message: {
                Text("Elle ne reviendra dans aucune liste. Cette action est irréversible.")
            }
            .alert("Action impossible", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private func restore(_ session: ArchivedSession) async {
        do {
            try await model.sessions(for: host, workspace: workspace).unarchive(session.sessionId)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteNow(_ sessionId: String?) async {
        guard let sessionId else { return }
        do {
            try await model.sessions(for: host, workspace: workspace).deleteArchivedNow(sessionId)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
