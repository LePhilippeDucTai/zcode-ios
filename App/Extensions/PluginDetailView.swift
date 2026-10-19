import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Détail d'un plugin : identité, description, composants et diagnostics, puis les actions (installer, mettre à jour,
/// activer, désinstaller, rétablir). Un plugin installé montre le détail de l'hôte (`listPlugins`, avec les hooks et les
/// serveurs MCP) ; un plugin du catalogue, ses composants lus à l'ouverture (`describePlugin`). Les plugins s'exécutent
/// sur l'hôte, jamais sur l'iPhone. Aucun lien n'est ouvert depuis l'app. Rien n'est affiché pour une donnée vide.
struct PluginDetailView: View {
    let model: PluginsModel
    let host: Host
    let pluginId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingInstall = false
    @State private var confirmingUninstall = false
    @State private var configuring = false
    /// La lecture des composants a été tentée (réussie ou non) : sans description, on affiche alors l'échec, plus l'attente.
    @State private var attempted = false

    var body: some View {
        let overview = model.overview
        let installed = overview?.installedPlugins.first { $0.id == pluginId }
        let available = (overview.map { $0.availablePlugins + $0.restorableBuiltins } ?? []).first { $0.id == pluginId }
        let info = model.details[pluginId]
        let description = model.descriptions[pluginId]
        let listing = installed?.listing ?? available?.listing
        let name = installed?.name ?? available?.name ?? info?.name ?? pluginId
        let marketplaceName = firstNonEmpty(installed?.marketplace, available?.marketplace, info?.marketplace)
        let marketplace = overview.flatMap { overview in marketplaceName.flatMap { PluginCatalogLayout.marketplace(named: $0, in: overview) } }
        let source = marketplaceName.flatMap { name in overview.flatMap { PluginCatalogLayout.sourceTitle(name, in: $0) } ?? name }
        let version = firstNonEmpty(installed?.version, available?.version, info?.version, description?.version)
        let author = firstNonEmpty(listing?.author, info?.author, description?.author)
        let homepage = firstNonEmpty(listing?.homepage, info?.homepage, description?.homepage)
        let summary = ExtensionsLabels.pluginDescription(
            firstNonEmpty(installed?.description, available?.description, info?.description), listing: listing)
        let diagnostics = (description?.diagnostics ?? []) + (overview?.diagnostics.filter { $0.pluginId == pluginId } ?? [])
        let restorable = overview?.restorableBuiltins.contains { $0.id == pluginId } ?? false
        // Un plugin désinstallé qui n'existe plus nulle part (source retirée) ne laisse pas un écran vide.
        let exists = overview == nil || installed != nil || available != nil || info != nil
        let displayName = ExtensionsLabels.pluginDisplayName(name, listing: listing)
        List {
            PluginNoticeSection(model: model)
            operationSection
            Section {
                identity(name: ExtensionsLabels.pluginDisplayName(name, listing: listing), version: version, source: source,
                         official: marketplace?.isOfficial == true, author: author, category: listing?.category,
                         installed: installed)
                if let homepage {
                    LabeledContent("Page d'accueil") {
                        Text(verbatim: homepage).textSelection(.enabled)
                    }
                }
            }
            actionsSection(
                installed: installed, available: available, restorable: restorable, displayName: displayName,
                configurable: info?.userConfig.isEmpty == false,
                orphan: installed.flatMap { plugin in overview.map { PluginCatalogLayout.isOrphan(plugin, in: $0) } } ?? false)
            if let summary {
                Section("Description") { Text(summary) }
            }
            componentsSection(info: info, description: description, installed: installed != nil, available: available)
            if !diagnostics.isEmpty {
                Section("Diagnostics") {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Label(ExtensionsLabels.diagnostic(diagnostic), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
        }
        .accessibilityIdentifier("plugin-detail")
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: exists) { _, stillExists in
            if !stillExists { dismiss() }
        }
        .confirmationDialog("Installer le plugin", isPresented: $confirmingInstall, titleVisibility: .hidden) {
            if let available {
                Button("Installer") { Task { await model.install(available) } }
                Button("Annuler", role: .cancel) {}
            }
        } message: {
            if let available {
                Text(ExtensionsLabels.installWarning(
                    plugin: available, marketplace: marketplace, hostName: host.name,
                    hasRunnableComponents: model.hasRunnableComponents(available)))
            }
        }
        .confirmationDialog("Désinstaller « \(displayName) » ?", isPresented: $confirmingUninstall, titleVisibility: .visible) {
            if let installed {
                Button("Désinstaller", role: .destructive) { Task { await model.uninstall(installed) } }
                Button("Annuler", role: .cancel) {}
            }
        } message: {
            // L'hôte désinstalle pour l'utilisateur, quelle que soit la portée affichée (Projet compris).
            Text("Désinstalle le plugin sur tout l'hôte \(host.name), quelle que soit la portée : supprime ses fichiers en cache, "
                + "son dossier de données et sa configuration enregistrée. Action irréversible.")
        }
        .sheet(isPresented: $configuring) {
            PluginConfigView(model: model, host: host, pluginId: pluginId)
        }
        .task(id: pluginId) {
            if let available, info == nil || installed == nil { await model.describe(available) }
            attempted = true
        }
        .pluginActionAlert(model, suppressed: configuring)
    }

    // MARK: - Actions

    /// Une opération est en cours (sur ce plugin ou un autre), ou l'hôte n'est pas lisible : aucune action.
    private var actionsDisabled: Bool { !model.canStartOperation }

    /// Progression de l'opération sur ce plugin : l'hôte n'en émet aucune, donc indicateur indéterminé et durée écoulée.
    @ViewBuilder private var operationSection: some View {
        if let operation = model.operation, operation.targetId == pluginId {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(ExtensionsLabels.operation(operation.kind))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ExtensionsLabels.elapsed(context.date.timeIntervalSince(operation.startedAt)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("plugin-progress")
                if operation.operationId != nil {
                    Button("Annuler", role: .cancel) { Task { await model.cancelOperation() } }
                        .accessibilityIdentifier("plugin-cancel")
                }
            }
        }
    }

    @ViewBuilder private func actionsSection(
        installed: InstalledPlugin?, available: AvailablePlugin?, restorable: Bool, displayName: String,
        configurable: Bool, orphan: Bool
    ) -> some View {
        if let installed {
            Section {
                Toggle(model.scope == .user ? "Activé pour l'utilisateur" : "Activé dans ce projet", isOn: Binding(
                    get: { installed.enabled },
                    set: { enabled in Task { await model.setEnabled(installed, enabled) } }
                ))
                .disabled(actionsDisabled)
                .accessibilityIdentifier("plugin-enabled")
                if installed.updateStatus != .none, !orphan {
                    Button(updateTitle(installed)) { Task { await model.update(installed) } }
                        .disabled(actionsDisabled)
                        .accessibilityIdentifier("plugin-update")
                }
                if configurable {
                    Button("Configurer") { configuring = true }
                        .disabled(actionsDisabled)
                        .accessibilityIdentifier("plugin-configure")
                }
                Button("Désinstaller", role: .destructive) { confirmingUninstall = true }
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("plugin-uninstall")
            } footer: {
                Text(ExtensionsLabels.pluginsTakeEffect)
            }
        } else if restorable, let available {
            // Un intégré masqué se rétablit : l'installer à nouveau n'aurait pas de sens.
            Section {
                Button("Rétablir") { Task { await model.restore(available) } }
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("plugin-restore-\(available.id)")
            } footer: {
                Text(ExtensionsLabels.pluginsTakeEffect)
            }
        } else if available != nil {
            Section {
                Button("Installer") { confirmingInstall = true }
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier("plugin-install")
            } footer: {
                Text(ExtensionsLabels.hostExecutionNote(hostName: host.name) + " " + ExtensionsLabels.pluginsTakeEffect)
            }
        }
    }

    private func updateTitle(_ plugin: InstalledPlugin) -> String {
        guard let latest = plugin.latestVersion, !latest.isEmpty else { return "Mettre à jour" }
        return "Mettre à jour vers \(latest)"
    }

    // MARK: - En-tête

    @ViewBuilder private func identity(
        name: String, version: String?, source: String?, official: Bool, author: String?, category: String?,
        installed: InstalledPlugin?
    ) -> some View {
        Text(name).font(ZCodeTypography.subheading)
        if let version { LabeledContent("Version", value: version) }
        if let source {
            LabeledContent("Source") {
                HStack(spacing: 6) {
                    Text(source)
                    if official { Badge(text: "Officiel", systemImage: "checkmark.seal") }
                }
            }
        }
        if let author { LabeledContent("Auteur", value: author) }
        if let category, !category.isEmpty { LabeledContent("Catégorie", value: ExtensionsLabels.category(category)) }
        if let installed {
            LabeledContent("État", value: installed.enabled ? "Activé" : "Désactivé")
        }
    }

    // MARK: - Composants

    @ViewBuilder private func componentsSection(
        info: PluginInfo?, description: PluginDescription?, installed: Bool, available: AvailablePlugin?
    ) -> some View {
        if installed, let info {
            componentsRows(groups: info.components, hooks: info.hookDetails, mcpServers: info.mcpServerNames)
        } else if let description {
            componentsRows(groups: description.components, hooks: [], mcpServers: [])
        } else if let available {
            Section("Composants") {
                if attempted {
                    Text("Composants indisponibles").foregroundStyle(.secondary)
                    Button("Réessayer") { Task { await model.describe(available) } }
                } else {
                    ProgressView("Lecture des composants…")
                }
            }
        }
    }

    @ViewBuilder private func componentsRows(
        groups: [PluginComponentGroup], hooks: [PluginHookDetail], mcpServers: [String]
    ) -> some View {
        // Les hooks et les serveurs MCP détaillés remplacent leur groupe générique, pour ne pas les montrer deux fois.
        let shown = groups.filter { group in
            !group.items.isEmpty
                && !(group.kind == .hook && !hooks.isEmpty)
                && !(group.kind == .mcp && !mcpServers.isEmpty)
        }
        Section {
            if shown.isEmpty, hooks.isEmpty, mcpServers.isEmpty {
                Text("Aucun composant déclaré").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown, id: \.kind.rawValue) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ExtensionsLabels.componentKind(group.kind)).font(.subheadline.weight(.semibold))
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.callout)
                                    if let text = item.description, !text.isEmpty {
                                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    if !hooks.isEmpty { hooksBlock(hooks) }
                    if !mcpServers.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ExtensionsLabels.componentKind(.mcp)).font(.subheadline.weight(.semibold))
                            ForEach(mcpServers, id: \.self) { Text($0).font(ZCodeTypography.code) }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugin-components")
            }
        } header: {
            Text("Composants")
        }
    }

    private func hooksBlock(_ hooks: [PluginHookDetail]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ExtensionsLabels.componentKind(.hook)).font(.subheadline.weight(.semibold))
            ForEach(Array(hooks.enumerated()), id: \.offset) { _, hook in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hook.event).font(ZCodeTypography.code)
                    Text(hook.command)
                        .font(ZCodeTypography.code)
                        .textSelection(.enabled)
                    Text(hook.runnable ? "Commande exécutée sur l'hôte." : "Commande non exécutable sur cet hôte.")
                        .font(.caption)
                        .foregroundStyle(hook.runnable ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { $0 }.first { !$0.isEmpty }
    }
}
