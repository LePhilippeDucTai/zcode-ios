import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Catalogue des plugins par source, avec recherche et filtre de catégorie. Aucune icône distante : les images du
/// catalogue vivent sur un CDN que l'app ne contacte pas.
struct PluginCatalogView: View {
    let model: PluginsModel
    let host: Host
    @State private var query = ""
    @State private var category: String?

    var body: some View {
        let layout = model.layout(query: query, category: category)
        List {
            PluginNoticeSection(model: model)
            ForEach(layout.catalog) { section in
                Section {
                    ForEach(section.plugins) { plugin in
                        row(plugin)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.title)
                        if section.isOfficial {
                            Badge(text: "Officiel", systemImage: "checkmark.seal")
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("plugins-catalog-list")
        .navigationTitle("Catalogue")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Rechercher un plugin")
        .overlay { emptyState(layout) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { categoryMenu(layout.categories) }
        }
        .pluginActionAlert(model)
    }

    @ViewBuilder private func emptyState(_ layout: PluginCatalogLayout) -> some View {
        if layout.catalog.isEmpty {
            if model.overview == nil {
                ContentUnavailableView("Catalogue indisponible", systemImage: "puzzlepiece.extension",
                                       description: Text("Actualise la liste des plugins."))
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty, category == nil {
                ContentUnavailableView("Catalogue vide", systemImage: "puzzlepiece.extension",
                                       description: Text("Aucune source de l'hôte ne propose de plugin."))
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Aucun plugin dans cette catégorie", systemImage: "puzzlepiece.extension")
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func categoryMenu(_ categories: [String]) -> some View {
        Menu {
            Button {
                category = nil
            } label: {
                if category == nil {
                    Label("Toutes les catégories", systemImage: "checkmark")
                } else {
                    Text("Toutes les catégories")
                }
            }
            ForEach(categories, id: \.self) { candidate in
                Button {
                    category = candidate
                } label: {
                    if candidate == category {
                        Label(ExtensionsLabels.category(candidate), systemImage: "checkmark")
                    } else {
                        Text(ExtensionsLabels.category(candidate))
                    }
                }
            }
        } label: {
            Label(category.map(ExtensionsLabels.category) ?? "Catégorie", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("plugins-category")
    }

    private func row(_ plugin: AvailablePlugin) -> some View {
        let description = ExtensionsLabels.pluginDescription(plugin.description, listing: plugin.listing)
        var kinds: [PluginComponentKind] = []
        for kind in plugin.componentTypes where !kinds.contains(kind) { kinds.append(kind) }
        return NavigationLink {
            PluginDetailView(model: model, host: host, pluginId: plugin.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)).font(.headline)
                    if plugin.installed {
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Installé")
                    }
                }
                if let description {
                    Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if !kinds.isEmpty {
                    Label(kinds.map(ExtensionsLabels.componentKind).joined(separator: " · "), systemImage: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if plugin.listing?.requiresPaidPlan == true {
                    Badge(text: "Coding Plan payant", systemImage: "creditcard")
                }
            }
        }
        .accessibilityIdentifier("plugin-row-\(plugin.id)")
    }
}
