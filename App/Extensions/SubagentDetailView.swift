import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Détail d'un sous-agent, en lecture seule ; pour un agent intégré ou de plugin, réglage du modèle imposé ; pour un
/// agent personnalisé, suppression.
struct SubagentDetailView: View {
    let model: SubagentsModel
    let host: Host
    /// L'agent tel que la liste l'a donné à l'ouverture : suivi dans les relectures par identifiant **et** chemin (deux
    /// projets peuvent avoir un agent de même nom), et gardé tel quel s'il n'y est plus (suppression, renommage).
    let fallback: AgentSummary
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: AgentSummary?
    @State private var editingAgent: AgentSummary?

    private var agent: AgentSummary { model.agent(id: fallback.id, path: fallback.path) ?? fallback }

    var body: some View {
        let agent = agent
        let catalog = app.modelCatalog(for: host)
        let canOverride = agent.source == .builtIn || agent.source == .plugin
        List {
            Section {
                LabeledContent("Provenance", value: ExtensionsLabels.provenance(agent))
                LabeledContent("Portée", value: ExtensionsLabels.scope(model.scope))
                if let color = agent.color {
                    LabeledContent("Couleur") {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill").foregroundStyle(AgentColors.swiftUI(color)).accessibilityHidden(true)
                            Text(ExtensionsLabels.color(color))
                        }
                    }
                }
                LabeledContent("Modèle", value: ExtensionsLabels.model(
                    agent.modelSelectionOverride ?? agent.modelSelection, catalog: catalog.view, inherit: "Modèle de la session"))
                LabeledContent("Outils", value: ExtensionsLabels.tools(agent.tools))
                if agent.scope != .builtIn {
                    Text(agent.path)
                        .font(ZCodeTypography.monoCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if canOverride {
                Section {
                    ModelEffortPicker(
                        selection: Binding(
                            get: { agent.modelSelectionOverride },
                            set: { selection in Task { await model.setModelOverride(agent, selection) } }),
                        catalog: catalog.view,
                        inheritLabel: inheritLabel(agent, catalog: catalog.view),
                        modelIdentifier: "subagent-model-override",
                        effortIdentifier: "subagent-effort-override")
                    if agent.modelSelectionOverride != nil {
                        Button("Rétablir") { Task { await model.setModelOverride(agent, nil) } }
                            .accessibilityIdentifier("subagent-model-reset")
                    }
                } header: {
                    Text("Modèle imposé")
                } footer: {
                    // L'hôte range ce choix dans `~/.zcode/v2/agents-state.json` : il vaut pour tout l'hôte, pas pour la
                    // seule portée affichée.
                    Text("Vaut sur tout l'hôte \(host.name), quelle que soit la portée. " + ExtensionsLabels.subagentsTakeEffect)
                }
                .disabled(model.isReadOnly || model.busy)
            }
            if !agent.description.isEmpty {
                Section("Description") {
                    Text(SubagentForm.displayDescription(of: agent))
                }
            }
            if !agent.systemPrompt.isEmpty {
                Section("Instructions") {
                    Text(agent.systemPrompt).font(.callout)
                }
            }
            if !agent.diagnostics.isEmpty {
                Section("Diagnostics") {
                    ForEach(Array(agent.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ExtensionsLabels.masked(diagnostic.message))
                            if !diagnostic.code.isEmpty {
                                Text(diagnostic.code).font(ZCodeTypography.monoCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if agent.isEditable {
                Section {
                    Button("Supprimer", role: .destructive) { confirmingDelete = agent }
                        .disabled(model.isReadOnly || model.busy)
                        .accessibilityIdentifier("subagent-delete")
                }
            }
            if case .failed = model.phase, model.list != nil {
                Section {
                    SubagentOfflineBanner(offline: model.isOffline)
                }
            }
            if let notice = model.notice {
                Section {
                    SubagentNoticeLabel(text: notice)
                }
            }
        }
        .accessibilityIdentifier("subagent-detail")
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await catalog.startIfNeeded() }
        .toolbar {
            if agent.isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Modifier") { editingAgent = agent }
                        .disabled(model.isReadOnly || model.busy)
                        .accessibilityIdentifier("subagent-edit")
                }
            }
        }
        .sheet(item: $editingAgent) { target in
            SubagentEditorView(host: host, model: model, editing: target)
        }
        .subagentActionAlert(model, suppressed: editingAgent != nil)
        .deleteSubagentConfirmation(for: $confirmingDelete) { target in
            Task {
                await model.delete(target)
                // Fermé seulement si le fichier a bien disparu de la liste relue.
                if model.agent(id: target.id, path: target.path) == nil { dismiss() }
            }
        }
    }

    private func inheritLabel(_ agent: AgentSummary, catalog: ModelSelectionView?) -> String {
        guard agent.source == .plugin else { return "Modèle de la session" }
        guard let defaultSelection = agent.defaultModelSelection ?? agent.modelSelection else { return "Défaut du plugin" }
        return "Défaut du plugin : \(ExtensionsLabels.model(defaultSelection, catalog: catalog, inherit: ""))"
    }
}
