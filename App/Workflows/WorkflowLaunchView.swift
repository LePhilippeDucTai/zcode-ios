import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Feuille de lancement d'un workflow enregistré : description, quand l'utiliser, un champ par argument.
struct WorkflowLaunchView: View {
    let model: SavedWorkflowsModel
    let workflow: SavedWorkflow
    /// Appelée avec la session créée, après fermeture de la feuille.
    let onLaunched: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var form: WorkflowArgsForm
    @State private var touched: Set<String> = []
    /// Vrai une fois « Lancer » grisé par des erreurs : toutes les erreurs sont alors montrées.
    private var revealAll: Bool { form.payload() == nil }
    @State private var failure: (message: String, detail: String?)?

    init(model: SavedWorkflowsModel, workflow: SavedWorkflow, onLaunched: @escaping (String) -> Void) {
        self.model = model
        self.workflow = workflow
        self.onLaunched = onLaunched
        _form = State(initialValue: WorkflowArgsForm(specs: workflow.args))
    }

    var body: some View {
        let errors = form.errors
        NavigationStack {
            Form {
                Section {
                    if !workflow.description.isEmpty { Text(workflow.description) }
                    if let whenToUse = workflow.whenToUse, !whenToUse.isEmpty {
                        Text(whenToUse).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach($form.fields) { $field in
                    Section {
                        input($field)
                        if revealAll || touched.contains(field.id), let message = errors[field.id] {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    } footer: {
                        Text(footer(field.spec))
                    }
                }
                if let failure {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            if let detail = failure.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workflow-launch-error")
                    }
                }
            }
            .navigationTitle(workflow.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }.disabled(model.launching)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lancer") { Task { await launch() } }
                        .disabled(form.payload() == nil || model.launching)
                        .accessibilityIdentifier("workflow-launch")
                }
            }
        }
        .interactiveDismissDisabled(model.launching)
    }

    @ViewBuilder
    private func input(_ field: Binding<WorkflowArgsForm.Field>) -> some View {
        let spec = field.wrappedValue.spec
        let id = "workflow-arg-\(spec.name)"
        let text = Binding(get: { field.wrappedValue.text }, set: { field.wrappedValue.text = $0; touched.insert(spec.name) })
        let flag = Binding(get: { field.wrappedValue.flag ?? false }, set: { field.wrappedValue.flag = $0; touched.insert(spec.name) })
        if spec.type == .boolean {
            Toggle(spec.name, isOn: flag).accessibilityIdentifier(id)
        } else if spec.type == .number {
            LabeledContent(spec.name) {
                TextField("Nombre", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(id)
            }
        } else if spec.type == .string {
            LabeledContent(spec.name) {
                TextField("Texte", text: text).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(id)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.name)
                TextEditor(text: text)
                    .font(ZCodeTypography.monoCaption)
                    .frame(minHeight: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(id)
            }
        }
    }

    private func footer(_ spec: WorkflowArgSpec) -> String {
        [spec.description, spec.required ? "Requis" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func launch() async {
        failure = nil
        switch await model.launch(workflow, args: form.payload()) {
        case .started(let sessionId, _):
            dismiss()
            onLaunched(sessionId)
        case .failed(let message, let detail):
            failure = (message, detail)
        }
    }
}
