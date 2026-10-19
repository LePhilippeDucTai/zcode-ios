import SwiftUI
import ZCodeAppCore

struct HostView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var showingWeb = false
    @State private var showingProjectPicker = false
    @State private var offlineBytes = 0
    @State private var confirmingClearOffline = false

    var body: some View {
        let connection = model.connection(for: host)
        List {
            if case .failed(let failure) = connection.state {
                // Sans cette alerte, rien ne dirait pourquoi les projets manquent (le détail est aussi dans la bulle).
                Section {
                    Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .accessibilityIdentifier("host-connection-alert")
                    Button("Réessayer") { Task { await connection.connect() } }
                        .accessibilityIdentifier("host-connection-retry")
                }
            } else {
                // En échec, l'alerte suffit : « Aucune session en cours » ou « Recherche… » sans fin tromperaient.
                ActiveSessionsSection(host: host)
            }
            Section {
                Picker("Mode", selection: defaultMode) {
                    Text("Défaut de l'hôte").tag(String?.none)
                    ForEach(ModeOption.all) { option in
                        Text(option.label).tag(Optional(option.id))
                    }
                }
                .accessibilityIdentifier("host-default-mode")
            } header: {
                Text("Nouvelles sessions")
            } footer: {
                Text(ModeOption.defaultModeNote(for: defaultMode.wrappedValue))
            }
            Section {
                NavigationLink(value: ExtensionsRoute(hostId: host.id, workspace: nil)) {
                    Label("Plugins et sous-agents", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("host-extensions")
            } header: {
                Text("Extensions")
            } footer: {
                Text("Portée Utilisateur : vaut pour tous les projets de cet hôte.")
            }
            Section("Projets") {
                ForEach(connection.workspaces, id: \.self) { path in
                    NavigationLink(value: WorkspaceRoute(hostId: host.id, path: path)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(filePath: path).lastPathComponent).font(.headline)
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("workspace-\(path)")
                    .swipeActions {
                        if model.hostStore.host(id: host.id)?.manualWorkspaces.contains(path) == true {
                            Button("Retirer", role: .destructive) {
                                model.hostStore.removeWorkspace(path, from: host.id)
                                model.refreshHost(host.id)
                            }
                        }
                    }
                }
                Button { showingProjectPicker = true } label: {
                    Label("Ajouter un projet", systemImage: "folder.badge.plus")
                }
            }
            Section {
                LabeledContent("Cache hors ligne", value: OfflineLabels.size(offlineBytes))
                Button("Vider le cache hors ligne", role: .destructive) { confirmingClearOffline = true }
                .disabled(offlineBytes == 0)
                .accessibilityIdentifier("host-offline-cache")
            } header: {
                Text("Hors ligne")
            } footer: {
                Text("Copie des dernières conversations ouvertes, lisible sans connexion à l'hôte.")
            }
        }
        .navigationTitle(host.name)
        .task {
            offlineBytes = await model.offlineCacheBytes(for: host)
        }
        .task {
            if connection.state == .idle { await connection.connect() }
        }
        // Relancé quand la liste des projets change et à chaque connexion établie (« Réessayer », reconnexion
        // automatique) : les listes en échec repartent. `watchActiveSessions` attend lui-même la connexion.
        .task(id: model.activeSessionsWatchKey(for: host)) {
            await model.watchActiveSessions(for: host)
        }
        .refreshable {
            await connection.connect()
            await model.refreshActiveSessions(for: host)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ConnectionStatusButton(connection: connection)
                Button { showingWeb = true } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Ouvrir dans l'interface web")
                    .accessibilityIdentifier("host-web")
                NavigationLink(value: UsageRoute(hostId: host.id)) { Image(systemName: "chart.bar.xaxis") }
                    .accessibilityLabel("Utilisation du Coding Plan")
                    .accessibilityIdentifier("host-usage")
            }
        }
        .navigationDestination(for: WorkspaceRoute.self) { route in
            SessionsView(host: host, workspace: route.path)
        }
        .navigationDestination(for: UsageRoute.self) { _ in
            UsageView(host: host)
        }
        // Seule déclaration : sert aussi à la liste d'un projet (`SessionsView`) et aux sessions en cours de la fiche.
        .navigationDestination(for: SessionRoute.self) { route in
            ChatView(host: host, route: route)
        }
        // Seule déclaration : elle sert aussi aux vues poussées depuis `SessionsView` (entrée « Extensions » du projet).
        .navigationDestination(for: ExtensionsRoute.self) { route in
            ExtensionsView(host: host, workspace: route.workspace)
        }
        .sheet(isPresented: $showingWeb) {
            WebFallbackView(url: model.webInterfaceURL(for: host))
        }
        .confirmationDialog("Vider le cache hors ligne ?", isPresented: $confirmingClearOffline, titleVisibility: .visible) {
            Button("Vider", role: .destructive) {
                Task {
                    await model.clearOfflineCache(for: host)
                    offlineBytes = await model.offlineCacheBytes(for: host)
                }
            }
        } message: {
            Text("Les copies des conversations de cet hôte seront supprimées. Les conversations encore ouvertes dans l'app seront de nouveau copiées au prochain passage en arrière-plan.")
        }
        .sheet(isPresented: $showingProjectPicker) {
            ProjectPickerView(host: host, connection: connection)
        }
    }

    /// Mode des nouvelles sessions (`nil` : « Défaut de l'hôte », aucune config envoyée à la création).
    private var defaultMode: Binding<String?> {
        Binding(get: { model.hostStore.host(id: host.id)?.defaultMode },
                set: { model.setDefaultMode($0, for: host) })
    }
}
