import SwiftUI
import ZCodeAppCore

/// Valider (et éventuellement pousser) les modifications du projet. Message vide : généré par le modèle courant de
/// l'hôte au moment de valider, comme dans l'interface web.
struct CommitSheet: View {
    let changes: WorkspaceChangesModel
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUnstaged: Bool

    init(changes: WorkspaceChangesModel) {
        self.changes = changes
        _includeUnstaged = State(initialValue: changes.staged.isEmpty)
    }

    private var pendingCount: Int { changes.unstaged.count + changes.untracked.count }
    private var fileCount: Int { changes.staged.count + (includeUnstaged ? pendingCount : 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message (vide : généré par l'IA)", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("commit-message")
                } footer: {
                    if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Un message sera généré par le modèle courant de l'hôte (un appel).")
                    }
                }
                if pendingCount > 0 {
                    Toggle("Inclure les modifications non indexées (\(pendingCount) fichier\(pendingCount > 1 ? "s" : ""))",
                           isOn: $includeUnstaged)
                        .accessibilityIdentifier("commit-include-unstaged")
                }
                Section {
                    Text("\(fileCount) fichier\(fileCount > 1 ? "s" : "") validé\(fileCount > 1 ? "s" : "")")
                        .foregroundStyle(.secondary)
                    if let error = changes.actionError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section {
                    Button { submit(push: false) } label: { progressLabel("Valider", running: changes.action == .commit || changes.action == .generateMessage) }
                        .accessibilityIdentifier("commit-submit")
                    Button { submit(push: true) } label: { progressLabel("Valider et pousser", running: changes.action == .push) }
                        .accessibilityIdentifier("commit-submit-push")
                }
                .disabled(changes.action != nil || fileCount == 0)
            }
            .navigationTitle(changes.summary?.branchName.map { "Valider sur \($0)" } ?? "Valider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(changes.action != nil)
    }

    @ViewBuilder
    private func progressLabel(_ title: String, running: Bool) -> some View {
        HStack {
            Text(title)
            if running { Spacer(); ProgressView() }
        }
    }

    private func submit(push: Bool) {
        Task {
            let committed = await changes.commit(message: message, includeUnstaged: includeUnstaged, push: push)
            // Commit fait : la feuille se ferme même si le push a échoué (message affiché dans l'écran).
            if committed { dismiss() }
        }
    }
}
