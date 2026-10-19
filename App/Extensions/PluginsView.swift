import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Alerte « Action impossible » de `PluginsModel.actionError`, partagée par la liste, le catalogue et le détail : seule la
/// vue visible la présente (les écrans précédents restent sous l'écran poussé, jamais deux alertes en même temps).
/// `suppressed` : une feuille est ouverte au-dessus et présente elle-même l'alerte.
private struct PluginActionAlert: ViewModifier {
    let model: PluginsModel
    var suppressed = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .alert("Action impossible", isPresented: Binding(
                get: { visible && !suppressed && model.actionError != nil },
                set: { if !$0 { model.dismissMessages() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }
}

extension View {
    func pluginActionAlert(_ model: PluginsModel, suppressed: Bool = false) -> some View {
        modifier(PluginActionAlert(model: model, suppressed: suppressed))
    }
}

/// Avis de la dernière action (succès, demande d'annulation), partagé par la liste, le catalogue et le détail.
struct PluginNoticeSection: View {
    let model: PluginsModel

    var body: some View {
        if let notice = model.notice {
            Section {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .accessibilityIdentifier("plugins-notice")
            }
        }
    }
}

/// Plugins d'une portée : installés, intégrés à rétablir et accès au catalogue. Hors ligne, l'aperçu lu reste affiché en
/// lecture seule. Les plugins s'exécutent sur l'hôte, jamais sur l'iPhone.
struct PluginsView: View {
    let model: PluginsModel
    let host: Host

    var body: some View {
        let layout = model.layout(query: "", category: nil)
        let overview = model.overview
        List {
            PluginNoticeSection(model: model)
            Section {
                Label(ExtensionsLabels.hostExecutionNote(hostName: host.name), systemImage: "desktopcomputer")
                    .font(.footnote)
                    .accessibilityIdentifier("plugins-host-note")
            } footer: {
                Text(ExtensionsLabels.pluginsTakeEffect)
            }
            statusSection
            if let overview {
                Section("Installés") {
                    if layout.installed.isEmpty {
                        Text("Aucun plugin installé").foregroundStyle(.secondary)
                    }
                    ForEach(layout.installed) { plugin in
                        installedRow(plugin, overview: overview)
                    }
                }
                if !layout.restorable.isEmpty {
                    Section {
                        ForEach(layout.restorable) { plugin in
                            NavigationLink {
                                PluginDetailView(model: model, host: host, pluginId: plugin.id)
                            } label: {
                                HStack {
                                    Text(ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing))
                                    Spacer()
                                    Button("Rétablir") { Task { await model.restore(plugin) } }
                                        .buttonStyle(.borderless)
                                        .disabled(!model.canStartOperation)
                                        .accessibilityIdentifier("plugin-restore-\(plugin.id)")
                                }
                            }
                            .accessibilityIdentifier("plugin-row-\(plugin.id)")
                        }
                    } header: {
                        Text("À rétablir")
                    } footer: {
                        Text("Plugins intégrés masqués.")
                    }
                }
                Section {
                    NavigationLink("Parcourir le catalogue (\(layout.catalog.reduce(0) { $0 + $1.plugins.count }))") {
                        PluginCatalogView(model: model, host: host)
                    }
                    .accessibilityIdentifier("plugins-catalog")
                }
            }
        }
        .accessibilityIdentifier("plugins-list")
        .overlay { loadingOverlay }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MarketplaceSourcesView(model: model, host: host)
                } label: {
                    Label("Sources", systemImage: "externaldrive.connected.to.line.below")
                }
                .accessibilityIdentifier("plugins-sources")
            }
        }
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .pluginActionAlert(model)
    }

    // MARK: - États

    @ViewBuilder private var statusSection: some View {
        if case .failed(let message) = model.phase {
            Section {
                if model.overview == nil {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("plugins-error")
                } else {
                    SubagentOfflineBanner(offline: model.isOffline, message: message)
                }
                Button("Réessayer") { Task { await model.refresh() } }
            }
        }
    }

    @ViewBuilder private var loadingOverlay: some View {
        if model.overview == nil, model.phase == .idle || model.phase == .loading {
            ProgressView("Chargement des plugins…")
        }
    }

    // MARK: - Ligne

    private func installedRow(_ plugin: InstalledPlugin, overview: PluginsOverview) -> some View {
        let orphan = PluginCatalogLayout.isOrphan(plugin, in: overview)
        let source = PluginCatalogLayout.sourceTitle(plugin.marketplace, in: overview)
        let identity = [plugin.version, source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let project = model.details[plugin.id]?.enabledSource == "workspace"
        return NavigationLink {
            PluginDetailView(model: model, host: host, pluginId: plugin.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)).font(.headline)
                if !identity.isEmpty {
                    Text(identity).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text((plugin.enabled ? "Activé" : "Désactivé") + (project ? " (projet)" : ""))
                    if plugin.updateStatus != .none, !orphan {
                        Badge(text: "Mise à jour", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if orphan {
                        Badge(text: "Source retirée", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("plugin-row-\(plugin.id)")
    }
}
