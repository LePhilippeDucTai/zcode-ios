import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Workflows enregistrés d'un projet : section « Projet » puis « Global ». Un toucher ouvre la feuille de lancement.
struct WorkflowsView: View {
    let host: Host
    let workspace: String
    @Environment(AppModel.self) private var app
    @State private var selected: SavedWorkflow?
    @State private var launchedSession: String?

    var body: some View {
        let model = app.savedWorkflows(for: host, workspace: workspace)
        List {
            section("Projet", list: model.project, error: model.projectError, firstInvalidIndex: 0)
            section("Global", list: model.global, error: model.globalError,
                    firstInvalidIndex: model.project?.invalid.count ?? 0)
        }
        .accessibilityIdentifier("workflows-list")
        .overlay {
            if model.phase == .loading, model.project == nil, model.global == nil {
                ProgressView("Chargement des workflows…")
            }
        }
        .navigationTitle("Workflows")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(item: $selected) { workflow in
            WorkflowLaunchView(model: model, workflow: workflow) { launchedSession = $0 }
        }
        .navigationDestination(item: $launchedSession) { sessionId in
            ChatView(host: host, route: SessionRoute(hostId: host.id, workspace: workspace, sessionId: sessionId))
        }
    }

    @ViewBuilder
    private func section(_ title: String, list: SavedWorkflowList?, error: String?, firstInvalidIndex: Int) -> some View {
        Section(title) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let list {
                ForEach(list.workflows) { workflow in
                    Button { selected = workflow } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name).font(.headline)
                            if !workflow.description.isEmpty {
                                Text(workflow.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("workflow-row-\(workflow.name)")
                }
                ForEach(Array(list.invalid.enumerated()), id: \.offset) { index, invalid in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(filePath: invalid.path).lastPathComponent).font(.headline)
                        Text(invalid.reason).font(.subheadline).lineLimit(3)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("workflow-invalid-\(firstInvalidIndex + index)")
                }
                if list.workflows.isEmpty, list.invalid.isEmpty, error == nil {
                    Text(WorkflowLabels.emptySection(dir: list.dir)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
