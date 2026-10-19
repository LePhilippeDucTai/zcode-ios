import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Dossier d'un projet ; la recherche porte sur tout le projet (recherche floue de l'hôte).
struct DirectoryView: View {
    let host: Host
    let route: DirectoryRoute
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let browser = model.fileBrowser(for: host, workspace: route.workspace)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        List {
            if searching {
                if let failure = browser.searchFailure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ForEach(browser.searchResults) { match in
                    link(isDirectory: match.isDirectory, path: match.path) {
                        Label(match.relativePath, systemImage: match.isDirectory ? "folder" : "doc")
                            .font(.callout.monospaced())
                    }
                }
            } else {
                switch browser.listing(route.path) {
                case .failed(let reason)?:
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Réessayer") { Task { await browser.load(route.path) } }
                case .loaded(let entries)?:
                    ForEach(entries) { entry in
                        link(isDirectory: entry.isDirectory, path: entry.path) {
                            Label {
                                Text(entry.name) + Text(entry.isSymbolicLink ? " ↗" : "").foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                            }
                        }
                        .accessibilityIdentifier("file-entry-\(entry.name)")
                    }
                case .loading?, nil:
                    EmptyView()
                }
            }
        }
        .accessibilityIdentifier("files-list")
        .overlay {
            if !searching {
                if browser.listing(route.path) == .loading {
                    ProgressView()
                } else if browser.listing(route.path) == .loaded([]) {
                    ContentUnavailableView("Dossier vide", systemImage: "folder")
                }
            }
        }
        .searchable(text: $query, prompt: "Rechercher dans le projet")
        .task(id: query) {
            // Une requête par pause de frappe ; une requête vide efface les résultats.
            guard searching else { await browser.search(""); return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await browser.search(query)
        }
        .task { await browser.load(route.path) }
        .refreshable { await browser.load(route.path) }
        .navigationTitle(route.path == route.workspace ? "Fichiers" : URL(filePath: route.path).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Afficher les fichiers cachés", isOn: Binding(
                        get: { browser.showsHidden },
                        set: { value in Task { await browser.setShowsHidden(value) } }))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func link<Content: View>(isDirectory: Bool, path: String, @ViewBuilder label: () -> Content) -> some View {
        if isDirectory {
            NavigationLink(value: DirectoryRoute(hostId: host.id, workspace: route.workspace, path: path), label: label)
        } else {
            NavigationLink(value: FileRoute(hostId: host.id, workspace: route.workspace, path: path), label: label)
        }
    }
}
