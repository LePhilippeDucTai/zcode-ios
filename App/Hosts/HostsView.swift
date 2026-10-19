import SwiftUI
import ZCodeAppCore

struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: HostEditorView.Mode?

    var body: some View {
        NavigationStack {
            Group {
                if model.hostStore.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun hôte", systemImage: "server.rack")
                    } description: {
                        Text("Ajoute un serveur ZCode joignable par Tailscale : son adresse https://…ts.net et son token.")
                    } actions: {
                        Button("Ajouter un hôte") { editor = .add }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(model.hostStore.hosts) { host in
                            NavigationLink(value: HostRoute(hostId: host.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).font(.headline)
                                    Text(host.baseURL.host() ?? host.baseURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Supprimer", role: .destructive) {
                                    Task { await model.removeHost(host.id) }
                                }
                                Button("Modifier") { editor = .edit(host) }
                                    .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hôtes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = .add } label: { Label("Ajouter un hôte", systemImage: "plus") }
                }
            }
            .navigationDestination(for: HostRoute.self) { route in
                if let host = model.hostStore.host(id: route.hostId) {
                    HostView(host: host)
                }
            }
            .sheet(item: $editor) { mode in
                HostEditorView(mode: mode)
            }
        }
    }
}
