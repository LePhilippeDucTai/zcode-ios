import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Feuille de configuration d'un plugin installé, dans la portée de l'écran (Utilisateur ou le projet). Une section par
/// option déclarée par le plugin ; seuls les champs modifiés partent vers l'hôte. Une option sensible se saisit en champ
/// masqué, n'est jamais relue et ne reste pas sur l'iPhone : le brouillon disparaît avec la feuille. Rien n'est affiché
/// pour une donnée vide.
struct PluginConfigView: View {
    let model: PluginsModel
    let host: Host
    let pluginId: String
    @Environment(\.dismiss) private var dismiss
    @State private var form: PluginConfigForm
    @State private var confirmingReset = false

    init(model: PluginsModel, host: Host, pluginId: String) {
        self.model = model
        self.host = host
        self.pluginId = pluginId
        let info = model.details[pluginId] ?? PluginInfo(id: pluginId, name: pluginId, marketplace: "", source: "")
        _form = State(initialValue: PluginConfigForm(scope: model.scope, plugin: info))
    }

    /// Cette feuille écrit (enregistrement ou réinitialisation de ce plugin) : elle ne se ferme pas avant la réponse. Une
    /// autre opération en cours ne la bloque pas.
    private var writing: Bool {
        guard let operation = model.operation, operation.targetId == pluginId else { return false }
        return operation.kind == .configure || operation.kind == .reset
    }

    var body: some View {
        let installed = model.overview?.installedPlugins.first { $0.id == pluginId }
        let name = ExtensionsLabels.pluginDisplayName(
            installed?.name ?? model.details[pluginId]?.name ?? pluginId, listing: installed?.listing)
        let issues = form.issues()
        let scope = ExtensionsLabels.scope(model.scope)
        NavigationStack {
            Form {
                if form.fields.isEmpty {
                    Section { Text("Aucune option à configurer").foregroundStyle(.secondary) }
                }
                ForEach($form.fields) { $field in
                    fieldSection($field, issue: issues[field.id])
                }
                Section {
                    Button {
                        guard let installed else { return }
                        Task {
                            if await model.configure(installed, form: form) { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text("Enregistrer")
                            if model.operation?.kind == .configure {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(installed == nil || !issues.isEmpty || form.patch().isEmpty || !model.canStartOperation)
                    .accessibilityIdentifier("plugin-config-save")
                    Button("Réinitialiser", role: .destructive) { confirmingReset = true }
                        .disabled(installed == nil || !model.canStartOperation)
                        .accessibilityIdentifier("plugin-config-reset")
                } footer: {
                    Text("Enregistré sur \(ExtensionsLabels.target(hostName: host.name, scope: model.scope)). "
                        + "Les valeurs sensibles partent vers l'hôte et ne sont jamais conservées sur l'iPhone. "
                        + ExtensionsLabels.pluginsTakeEffect)
                }
            }
            .navigationTitle("Configurer « \(name) »")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .disabled(writing)
                        .accessibilityIdentifier("plugin-config-cancel")
                }
            }
            .confirmationDialog(
                "Réinitialiser la configuration de « \(name) » pour \(scope) ?", isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Réinitialiser", role: .destructive) {
                    guard let installed else { return }
                    Task {
                        if await model.resetConfig(installed) { dismiss() }
                    }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les valeurs enregistrées pour \(scope) sont supprimées.")
            }
            .pluginActionAlert(model)
        }
        .interactiveDismissDisabled(writing)
    }

    // MARK: - Une option

    private func fieldSection(_ field: Binding<PluginConfigForm.Field>, issue: String?) -> some View {
        let value = field.wrappedValue
        let key = value.id
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.title).font(.subheadline.weight(.semibold))
                    if value.source == "workspace" {
                        Badge(text: "défini par le projet", systemImage: "folder")
                    }
                }
                if value.isCleared {
                    Text("Sera effacé à l'enregistrement.").foregroundStyle(.secondary)
                } else {
                    input(field)
                }
                if value.option.sensitive {
                    Text(value.isSet ? "Défini (masqué)" : "Non défini")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Seulement là où l'effacement a un effet sur l'hôte (règle de ZCode Web, `PluginConfigForm.Field.canClear`).
            if value.canClear {
                Button(value.isCleared ? "Annuler l'effacement" : "Effacer") {
                    field.wrappedValue.draft = value.isCleared ? nil : .clear
                }
                .accessibilityIdentifier("plugin-config-clear-\(key)")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let hint = value.hint { Text(hint) }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private func input(_ field: Binding<PluginConfigForm.Field>) -> some View {
        let value = field.wrappedValue
        if value.option.type == "boolean" {
            Toggle(value.title, isOn: Binding(
                get: { field.wrappedValue.isOn },
                set: { field.wrappedValue.draft = .toggle($0) }
            ))
            .labelsHidden()
            .accessibilityLabel(value.title)
            .accessibilityIdentifier("plugin-config-\(value.id)")
        } else {
            let text = Binding(
                get: { field.wrappedValue.text },
                set: { field.wrappedValue.draft = Self.draft(for: $0, in: field.wrappedValue) }
            )
            if value.option.sensitive {
                SecureField(value.isSet ? "Nouvelle valeur" : "Valeur", text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(value.title)
                    .accessibilityIdentifier("plugin-config-\(value.id)")
            } else {
                TextField("Valeur", text: text)
                    .keyboardType(value.option.type == "number" ? .decimalPad : .default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(value.title)
                    .accessibilityIdentifier("plugin-config-\(value.id)")
            }
        }
    }

    /// Un champ revenu à sa valeur actuelle (ou une valeur sensible vide) n'est plus modifié.
    private static func draft(for text: String, in field: PluginConfigForm.Field) -> PluginConfigForm.Draft? {
        let unchanged = field.option.sensitive ? text.isEmpty : text == field.currentText
        return unchanged ? nil : .value(text)
    }
}
