import SwiftUI
import ZCodeAppCore
import ZCodeV4

struct SessionsView: View {
    let host: Host
    let workspace: String
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var createError: String?
    @State private var createdSession: String?
    @State private var showingArchived = false
    @State private var renaming: RenameTarget?
    @State private var query = ""

    var body: some View {
        let sessions = model.sessions(for: host, workspace: workspace)
        let layout = sessions.layout(query: query)
        let savedWorkflows = model.savedWorkflows(for: host, workspace: workspace)
        List {
            if let date = sessions.offlineCopyDate {
                // Copie hors ligne : le bandeau gris remplace la section rouge « hôte injoignable ».
                Section {
                    OfflineBanner(savedAt: date, connecting: !isFailed(sessions.phase)) {
                        Task { await sessions.refresh() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else if case .failed(let reason) = sessions.phase {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Réessayer") { Task { await sessions.refresh() } }
                }
            }
            if !layout.drafts.isEmpty {
                Section {
                    ForEach(layout.drafts, id: \.self) { sessionId in
                        NavigationLink(value: SessionRoute(hostId: host.id, workspace: workspace, sessionId: sessionId)) {
                            SessionRowView(title: SessionListLayout.draftTitle, preview: "En attente du premier message",
                                           phase: .draft, pendingCount: 0, date: nil, unread: false)
                        }
                        .swipeActions {
                            if !sessions.isLocked {
                                Button("Supprimer", role: .destructive) { Task { await delete(sessionId) } }
                            }
                        }
                    }
                }
            }
            if !layout.waiting.isEmpty {
                Section {
                    ForEach(layout.waiting) { row($0, in: sessions) }
                } header: {
                    Text("En attente de vous").accessibilityIdentifier("sessions-section-waiting")
                }
            }
            if !layout.pinned.isEmpty {
                Section {
                    ForEach(layout.pinned) { row($0, in: sessions) }
                } header: {
                    Text("Épinglées").accessibilityIdentifier("sessions-section-pinned")
                }
            }
            if !layout.recent.isEmpty {
                Section {
                    ForEach(layout.recent) { row($0, in: sessions) }
                } header: {
                    // Titre seulement s'il y a d'autres sections : une liste simple reste sans en-tête.
                    if !layout.waiting.isEmpty || !layout.pinned.isEmpty {
                        Text("Récentes").accessibilityIdentifier("sessions-section-recent")
                    }
                }
            }
        }
        .accessibilityIdentifier("sessions-list")
        .searchable(text: $query, prompt: "Rechercher une session")
        .renameSessionAlert(host: host, workspace: workspace, target: $renaming)
        .overlay {
            if sessions.phase == .loading, sessions.sessions.isEmpty {
                ProgressView("Chargement des sessions…")
            } else if sessions.phase == .ready, layout.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Aucune session", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Crée une session avec le bouton en haut à droite."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle(URL(filePath: workspace).lastPathComponent)
        .task { await sessions.startIfNeeded() }
        .task { await savedWorkflows.checkAvailability() }
        .refreshable { await sessions.refresh() }
        .toolbar {
            if !sessions.isLocked {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await create(in: sessions) } } label: {
                        Label("Nouvelle session", systemImage: "square.and.pencil")
                    }
                    .disabled(creating)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingArchived = true
                } label: {
                    Label("Sessions archivées", systemImage: "archivebox")
                }
                .accessibilityIdentifier("sessions-archived")
                .disabled(sessions.archived.isEmpty || sessions.isLocked)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink(value: ChangesRoute(hostId: host.id, workspace: workspace)) {
                    Label("Modifications", systemImage: "arrow.triangle.branch")
                }
                .accessibilityIdentifier("workspace-changes")
                Spacer()
                NavigationLink(value: ExtensionsRoute(hostId: host.id, workspace: workspace)) {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("workspace-extensions")
                Spacer()
                if savedWorkflows.available == true, !sessions.isLocked {
                    NavigationLink(value: WorkflowsRoute(hostId: host.id, workspace: workspace)) {
                        Label("Workflows", systemImage: "flowchart")
                    }
                    .accessibilityIdentifier("workspace-workflows")
                    Spacer()
                }
                NavigationLink(value: DirectoryRoute(hostId: host.id, workspace: workspace, path: workspace)) {
                    Label("Fichiers", systemImage: "folder")
                }
                .accessibilityIdentifier("workspace-files")
            }
        }
        .sheet(isPresented: $showingArchived) {
            ArchivedSessionsView(host: host, workspace: workspace)
        }
        .navigationDestination(item: $createdSession) { sessionId in
            ChatView(host: host, route: SessionRoute(hostId: host.id, workspace: workspace, sessionId: sessionId))
        }
        .navigationDestination(for: WorkflowsRoute.self) { route in
            WorkflowsView(host: host, workspace: route.workspace)
        }
        .navigationDestination(for: ChangesRoute.self) { route in
            WorkspaceChangesView(host: host, workspace: route.workspace)
        }
        .navigationDestination(for: GitDiffRoute.self) { route in
            GitDiffView(host: host, route: route)
        }
        .navigationDestination(for: DirectoryRoute.self) { route in
            DirectoryView(host: host, route: route)
        }
        .navigationDestination(for: FileRoute.self) { route in
            FileView(host: host, workspace: route.workspace, path: route.path)
        }
        .alert("Action impossible", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
    }

    /// Ligne d'une session publiée : épingler (balayage vers la droite ou menu), archiver et renommer (balayage vers la
    /// gauche ou menu).
    private func row(_ summary: SessionSummary, in sessions: SessionsModel) -> some View {
        let pinned = sessions.isPinned(summary.sessionId)
        let title = summary.title.isEmpty ? SessionListLayout.untitledTitle : summary.title
        return NavigationLink(value: SessionRoute(hostId: host.id, workspace: workspace, sessionId: summary.sessionId)) {
            SessionRowView(title: title, preview: summary.lastAssistantPreview, phase: summary.phase,
                           pendingCount: summary.pendingCount, date: summary.lastActivityDate,
                           unread: sessions.isUnread(summary), pinned: pinned,
                           workflow: WorkflowLabels.activity(summary.workflowActivity?.runs))
        }
        .swipeActions(edge: .leading) {
            if !sessions.isLocked {
                Button { sessions.togglePin(summary.sessionId) } label: {
                    Label(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin")
                }
                .tint(.yellow)
                .accessibilityIdentifier("session-pin-\(summary.sessionId)")
            }
        }
        .swipeActions {
            if !sessions.isLocked {
                // Sans confirmation : la ligne disparaît tout de suite (retrouvable dans « Sessions archivées »).
                Button(role: .destructive) { Task { await archive(summary.sessionId) } } label: {
                    Label("Archiver", systemImage: "archivebox")
                }
                .tint(.orange)
                Button("Renommer") {
                    renaming = RenameTarget(sessionId: summary.sessionId, currentTitle: summary.title.isEmpty ? nil : summary.title)
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if !sessions.isLocked {
                Button { sessions.togglePin(summary.sessionId) } label: {
                    Label(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin")
                }
                Button {
                    renaming = RenameTarget(sessionId: summary.sessionId, currentTitle: summary.title.isEmpty ? nil : summary.title)
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                Button(role: .destructive) { Task { await archive(summary.sessionId) } } label: {
                    Label("Archiver", systemImage: "archivebox")
                }
            }
        }
    }

    private func isFailed(_ phase: SessionsModel.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func create(in sessions: SessionsModel) async {
        creating = true
        defer { creating = false }
        do {
            createdSession = try await sessions.createSession(builder: model.builder)
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ sessionId: String) async {
        do {
            try await model.deleteSession(host: host, workspace: workspace, sessionId: sessionId)
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func archive(_ sessionId: String) async {
        do {
            try await model.archiveSession(host: host, workspace: workspace, sessionId: sessionId)
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
