import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Rubriques de l'écran « Extensions ».
enum ExtensionsSection: CaseIterable, Hashable {
    case plugins
    case subagents

    var title: String {
        switch self {
        case .plugins: "Plugins"
        case .subagents: "Sous-agents"
        }
    }
}

/// Extensions de l'hôte (plugins, sous-agents) pour une portée : l'utilisateur, ou l'un des projets de l'hôte. La cible de ce
/// qu'on modifie est toujours écrite en tête.
struct ExtensionsView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var scope: ExtensionScope
    @State private var section: ExtensionsSection = .plugins

    init(host: Host, workspace: String?) {
        self.host = host
        _scope = State(initialValue: workspace.map(ExtensionScope.workspace) ?? .user)
    }

    var body: some View {
        let connection = model.connection(for: host)
        let target = ExtensionsLabels.target(hostName: host.name, scope: scope)
        Group {
            switch section {
            case .plugins:
                PluginsView(model: model.plugins(for: host, scope: scope), host: host)
                    .id(scope)
            case .subagents:
                SubagentsListView(model: model.subagents(for: host, scope: scope), host: host)
                    .id(scope)
            }
        }
        .navigationTitle("Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(target)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                        .accessibilityValue(target)
                        .accessibilityIdentifier("extensions-target")
                    Spacer()
                    scopeMenu(connection)
                }
                if ExtensionsSection.allCases.count > 1 {
                    Picker("Rubrique", selection: $section) {
                        ForEach(ExtensionsSection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("extensions-segment")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task { await model.modelCatalog(for: host).startIfNeeded() }
    }

    private func scopeMenu(_ connection: HostConnection) -> some View {
        Menu {
            scopeButton(.user)
            ForEach(connection.workspaces, id: \.self) { scopeButton(.workspace($0)) }
        } label: {
            Label(ExtensionsLabels.scope(scope), systemImage: "scope")
                .font(.subheadline)
        }
        .accessibilityIdentifier("extensions-scope")
    }

    private func scopeButton(_ candidate: ExtensionScope) -> some View {
        Button {
            scope = candidate
        } label: {
            if candidate == scope {
                Label(ExtensionsLabels.scope(candidate), systemImage: "checkmark")
            } else {
                Text(ExtensionsLabels.scope(candidate))
            }
        }
    }
}
