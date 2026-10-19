import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Feuille de création (`editing == nil`) ou de modification d'un sous-agent personnalisé. Mêmes champs et mêmes règles que
/// ZCode Web ; tout ce que le formulaire ne montre pas est repris tel quel de l'agent modifié. Les défauts ne s'affichent
/// qu'une fois un champ modifié.
struct SubagentEditorView: View {
    let host: Host
    let model: SubagentsModel
    let editing: AgentSummary?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var form: SubagentForm
    @State private var touched = false
    @State private var advancedExpanded = false

    init(host: Host, model: SubagentsModel, editing: AgentSummary?) {
        self.host = host
        self.model = model
        self.editing = editing
        _form = State(initialValue: editing.map { SubagentForm(editing: $0, scope: model.scope) }
            ?? SubagentForm(scope: model.scope))
    }

    var body: some View {
        let catalog = app.modelCatalog(for: host)
        let issues = form.issues(existing: model.customAgents, editing: editing, catalog: catalog.view)
        NavigationStack {
            Form {
                identitySection
                Section("Modèle") {
                    ModelEffortPicker(
                        selection: $form.modelSelection,
                        catalog: catalog.view,
                        inheritLabel: "Modèle de la session",
                        modelIdentifier: "subagent-model",
                        effortIdentifier: "subagent-effort")
                }
                toolsSection
                instructionsSection
                advancedSection
                saveSection(issues)
            }
            .accessibilityIdentifier("subagent-editor")
            .navigationTitle(editing == nil ? "Nouveau sous-agent" : "Modifier le sous-agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                        .disabled(model.busy)
                        .accessibilityIdentifier("subagent-cancel")
                }
            }
            .onChange(of: form) { touched = true }
            .task { await catalog.startIfNeeded() }
            .subagentActionAlert(model)
        }
        .interactiveDismissDisabled(model.busy)
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section("Identité") {
            TextField("Nom", text: $form.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("subagent-name")
            TextField("Description", text: $form.description, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityIdentifier("subagent-description")
            Picker("Couleur", selection: $form.color) {
                ForEach(colorChoices, id: \.rawValue) { color in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(AgentColors.swiftUI(color))
                            .accessibilityHidden(true)
                        Text(ExtensionsLabels.color(color))
                    }
                    .tag(color)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("subagent-color")
        }
    }

    /// Les huit couleurs du web ; la couleur actuelle d'un agent, si l'app ne la connaît pas, reste proposée.
    private var colorChoices: [AgentColor] {
        AgentColor.webOrder.contains(form.color) ? AgentColor.webOrder : AgentColor.webOrder + [form.color]
    }

    private var toolsSection: some View {
        Section {
            Toggle("Tous les outils", isOn: $form.allTools)
                .accessibilityIdentifier("subagent-all-tools")
            if !form.allTools {
                ForEach(SubagentForm.knownTools, id: \.self) { tool in
                    Toggle(isOn: toolBinding(tool)) {
                        if SubagentForm.riskyTools.contains(tool) {
                            Label {
                                Text(tool)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            .accessibilityLabel("\(tool), modifie l'hôte")
                        } else {
                            Text(tool)
                        }
                    }
                    .accessibilityIdentifier("subagent-tool-\(tool)")
                }
                ForEach(Array(form.extraTools.enumerated()), id: \.offset) { _, tool in
                    LabeledContent("Autre outil", value: tool)
                        .font(ZCodeTypography.monoCaption)
                        .accessibilityIdentifier("subagent-extra-tool")
                }
                .onDelete { form.extraTools.remove(atOffsets: $0) }
            }
        } header: {
            Text("Outils")
        } footer: {
            if !form.allTools {
                Text("Bash, Edit et Write modifient l'hôte.")
            }
        }
    }

    private var instructionsSection: some View {
        Section("Instructions") {
            TextEditor(text: $form.systemPrompt)
                .frame(minHeight: 160)
                .autocorrectionDisabled()
                .accessibilityLabel("Instructions")
                .accessibilityIdentifier("subagent-prompt")
            Toggle("Joindre AGENTS.md du projet", isOn: $form.injectAgentsMd)
                .accessibilityIdentifier("subagent-inject-agents-md")
        }
    }

    /// Champs que le runtime honore au-delà du web, repliés par défaut.
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Avancé", isExpanded: $advancedExpanded) {
                disallowedToolsGroup
                TextField("Skills (une par ligne ou séparées par des virgules)", text: $form.skillsText, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("subagent-skills")
                TextField("Tours max (vide = sans limite)", text: $form.maxTurnsText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("subagent-max-turns")
                Toggle("Exécution en arrière-plan", isOn: $form.background)
                    .accessibilityIdentifier("subagent-background")
                if form.permissionModeEditable {
                    permissionModePicker
                }
                if let count = editing?.mcpServers?.count, count > 0 {
                    Text(ExtensionsLabels.mcpServers(count: count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subagent-mcp-servers")
                }
            }
            .accessibilityIdentifier("subagent-advanced")
        }
    }

    @ViewBuilder private var disallowedToolsGroup: some View {
        Text("Outils interdits")
            .font(.subheadline.weight(.semibold))
        ForEach(SubagentForm.knownTools, id: \.self) { tool in
            Toggle(tool, isOn: disallowedBinding(tool))
                .accessibilityIdentifier("subagent-disallowed-tool-\(tool)")
        }
        ForEach(Array(form.extraDisallowedTools.enumerated()), id: \.offset) { _, tool in
            HStack {
                Text(tool)
                    .font(ZCodeTypography.monoCaption)
                Spacer()
                Button(role: .destructive) {
                    form.extraDisallowedTools.removeAll { $0 == tool }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retirer \(tool)")
            }
            .accessibilityIdentifier("subagent-extra-disallowed-tool")
        }
    }

    @ViewBuilder private var permissionModePicker: some View {
        Picker("Mode d'autorisation", selection: $form.permissionMode) {
            Text("Défaut").tag(AgentPermissionMode?.none)
            ForEach(permissionModeChoices, id: \.rawValue) { mode in
                Text(ExtensionsLabels.permissionMode(mode)).tag(AgentPermissionMode?.some(mode))
            }
        }
        .accessibilityIdentifier("subagent-permission-mode")
        if form.permissionMode == .dontAsk || form.permissionMode == .bypassPermissions {
            Label(ExtensionsLabels.unattendedPermissionWarning, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Les six modes connus ; le mode actuel d'un agent, si l'app ne le connaît pas, reste proposé.
    private var permissionModeChoices: [AgentPermissionMode] {
        let known: [AgentPermissionMode] = [.defaultMode, .acceptEdits, .auto, .dontAsk, .bypassPermissions, .plan]
        guard let current = form.permissionMode, !known.contains(current) else { return known }
        return known + [current]
    }

    private func saveSection(_ issues: [SubagentFormIssue]) -> some View {
        Section {
            // Modèle et effort périmés se disent dès l'ouverture (Enregistrer serait grisé sans explication) ; le reste,
            // une fois un champ modifié.
            let shown = issues.filter { touched || $0 == .modelUnavailable || $0 == .effortUnsupported }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("subagent-issues")
            }
            Button {
                Task {
                    if await model.save(form, editing: editing) { dismiss() }
                }
            } label: {
                HStack {
                    Text("Enregistrer")
                    if model.busy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!issues.isEmpty || model.busy || model.isReadOnly)
            .accessibilityIdentifier("subagent-save")
        } footer: {
            Text("Enregistré sur \(ExtensionsLabels.target(hostName: host.name, scope: model.scope))")
        }
    }

    private func disallowedBinding(_ tool: String) -> Binding<Bool> {
        Binding(
            get: { form.disallowedTools.contains(tool) },
            set: { checked in
                if checked { form.disallowedTools.insert(tool) } else { form.disallowedTools.remove(tool) }
            })
    }

    private func toolBinding(_ tool: String) -> Binding<Bool> {
        Binding(
            get: { form.selectedTools.contains(tool) },
            set: { checked in
                if checked { form.selectedTools.insert(tool) } else { form.selectedTools.remove(tool) }
            })
    }
}
