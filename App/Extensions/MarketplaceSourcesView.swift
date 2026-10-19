import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Sources (marketplaces) de plugins de l'hôte : liste, actualisation, ajout vérifié et retrait. Les sources sont communes à
/// tout l'hôte, quelle que soit la portée. Une source non officielle peut fournir du code exécuté sur l'hôte, jamais sur
/// l'iPhone. Les identifiants d'une adresse sont masqués et les en-têtes d'une source ne sont jamais lus. Rien n'est
/// affiché pour une donnée vide.
struct MarketplaceSourcesView: View {
    let model: PluginsModel
    let host: Host
    @State private var adding = false
    @State private var pendingRemoval: MarketplaceSummary?

    var body: some View {
        List {
            PluginNoticeSection(model: model)
            operationSection
            if let overview = model.overview {
                Section {
                    if overview.marketplaces.isEmpty {
                        Text("Aucune source").foregroundStyle(.secondary)
                    }
                    ForEach(overview.marketplaces) { marketplace in
                        row(marketplace)
                    }
                } footer: {
                    Text("Les sources sont communes à tout l'hôte \(host.name), quelle que soit la portée.")
                }
            }
        }
        .accessibilityIdentifier("sources-list")
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyState }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canStartOperation)
                .accessibilityIdentifier("sources-refresh")
                Button {
                    adding = true
                } label: {
                    Label("Ajouter", systemImage: "plus")
                }
                .disabled(!model.canStartOperation)
                .accessibilityIdentifier("sources-add")
            }
        }
        .sheet(isPresented: $adding) {
            AddSourceSheet(model: model, host: host)
        }
        .confirmationDialog(
            "Retirer la source « \(pendingRemoval.map(ExtensionsLabels.marketplaceTitle) ?? "") » ?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { marketplace in
            Button("Retirer", role: .destructive) { Task { await model.removeSource(marketplace) } }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Les plugins déjà installés depuis cette source restent, sans mises à jour.")
        }
        .task { await model.loadIfNeeded() }
        .pluginActionAlert(model, suppressed: adding)
    }

    // MARK: - États

    @ViewBuilder private var emptyState: some View {
        if model.overview == nil {
            switch model.phase {
            case .failed(let message):
                ContentUnavailableView("Sources indisponibles", systemImage: "externaldrive.badge.xmark",
                                       description: Text(message))
            default:
                ProgressView("Chargement des sources…")
            }
        }
    }

    /// Progression d'une opération sur les sources : l'hôte n'en émet aucune, donc indicateur indéterminé et durée écoulée.
    @ViewBuilder private var operationSection: some View {
        if let operation = model.operation, Self.isSourceOperation(operation.kind) {
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

    private static func isSourceOperation(_ kind: PluginOperation.Kind) -> Bool {
        kind == .addSource || kind == .removeSource || kind == .refreshSources
    }

    // MARK: - Ligne

    private func row(_ marketplace: MarketplaceSummary) -> some View {
        let kind = marketplace.sourceKind.flatMap { $0.isEmpty ? nil : ExtensionsLabels.sourceKind($0) }
        let origin = [kind, ExtensionsLabels.sourceLabel(marketplace)].compactMap { $0 }.joined(separator: " · ")
        let updated = marketplace.lastUpdated.map { Self.relative.localizedString(for: $0, relativeTo: .now) }
        let facts = [Self.count(marketplace.pluginCount), updated.map { "Actualisée \($0)" }].compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(ExtensionsLabels.marketplaceTitle(marketplace)).font(.headline)
                if marketplace.isOfficial {
                    Badge(text: "Officiel", systemImage: "checkmark.seal")
                }
            }
            if !origin.isEmpty {
                Text(verbatim: origin).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(facts).font(.caption).foregroundStyle(.secondary)
            if let failure = marketplace.refreshFailure, !failure.isEmpty {
                Label(ExtensionsLabels.masked(failure), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("source-row-\(marketplace.id)")
        .swipeActions {
            if !marketplace.isOfficial {
                Button("Retirer", role: .destructive) { pendingRemoval = marketplace }
                    .disabled(!model.canStartOperation)
                    .accessibilityIdentifier("source-remove-\(marketplace.id)")
            }
        }
    }

    private static func count(_ plugins: Int) -> String { plugins > 1 ? "\(plugins) plugins" : "\(plugins) plugin" }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr")
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// Feuille d'ajout d'une source. Le texte est contrôlé en local avant tout appel (chemin relatif refusé), puis peut être
/// vérifié par l'hôte sans être ajouté. La feuille ne se ferme pas pendant l'ajout, ni sur un refus.
private struct AddSourceSheet: View {
    let model: PluginsModel
    let host: Host
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var validating = false
    @State private var validation: Validation?

    private enum Validation: Equatable {
        case valid
        case invalid(String)
    }

    private var writing: Bool { model.operation?.kind == .addSource }

    var body: some View {
        let issue = PluginsModel.sourceIssue(text)
        NavigationStack {
            Form {
                Section {
                    TextField("owner/repo, https://… ou /chemin/sur/l'hôte", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("source-field")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dépôt GitHub (owner/repo, puis #branche si besoin), adresse https:// d'un dépôt git ou d'un fichier "
                            + ".json, user@hôte:chemin pour git, ou chemin absolu (ou ~) d'un dossier ou d'un fichier .json "
                            + "sur \(host.name).")
                        if let issue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button {
                        verify()
                    } label: {
                        HStack {
                            Text("Vérifier")
                            if validating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(issue != nil || validating)
                    .accessibilityIdentifier("source-validate")
                    if let validation {
                        validationLabel(validation)
                    }
                } footer: {
                    Text("L'hôte examine la source sans l'ajouter.")
                }
                Section {
                    Label("Une source non officielle peut fournir du code exécuté sur l'hôte.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button {
                        Task {
                            if await model.addSource(text) { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text("Ajouter")
                            if writing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(issue != nil || !model.canStartOperation)
                    .accessibilityIdentifier("source-submit")
                    if writing, model.operation?.operationId != nil {
                        Button("Annuler l'ajout", role: .cancel) { Task { await model.cancelOperation() } }
                            .accessibilityIdentifier("plugin-cancel")
                    }
                }
            }
            .navigationTitle("Ajouter une source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .disabled(writing)
                        .accessibilityIdentifier("source-close")
                }
            }
            .onChange(of: text) { validation = nil }
            .pluginActionAlert(model)
        }
        .interactiveDismissDisabled(writing)
    }

    @ViewBuilder private func validationLabel(_ validation: Validation) -> some View {
        switch validation {
        case .valid:
            Label("Source valide", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("source-validation")
        case .invalid(let message):
            Label(ExtensionsLabels.masked(message), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("source-validation")
        }
    }

    /// Le résultat ne vaut que pour le texte vérifié : un texte modifié entre-temps l'écarte.
    private func verify() {
        let checked = text
        validating = true
        Task {
            let message = await model.validateSource(checked)
            validating = false
            if checked == text { validation = message.map(Validation.invalid) ?? .valid }
        }
    }
}
