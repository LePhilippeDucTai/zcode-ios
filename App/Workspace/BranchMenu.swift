import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Branche courante ; le menu bascule sur une autre branche locale ou en crée une. Si des modifications seraient
/// écrasées, propose de les valider puis de rebasculer (comme l'interface web).
struct BranchMenu: View {
    let changes: WorkspaceChangesModel
    @State private var creating = false
    @State private var newName = ""
    @State private var blocked: (branch: String, paths: [String])?

    var body: some View {
        Menu {
            ForEach(changes.branches) { branch in
                Button { change { await changes.switchBranch(to: branch.name) } } label: {
                    if branch.isCurrent { Label(branch.name, systemImage: "checkmark") } else { Text(branch.name) }
                }
                .accessibilityIdentifier("branch-\(branch.name)")
            }
            Divider()
            Button("Nouvelle branche…", systemImage: "plus") { newName = ""; creating = true }
                .accessibilityIdentifier("branch-new")
        } label: {
            Label(label, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
        }
        .disabled(changes.action != nil)
        .accessibilityIdentifier("git-branch")
        .task { await changes.loadBranches() }
        .alert("Nouvelle branche", isPresented: $creating) {
            TextField("feature/ma-branche", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Créer et basculer") { change { await changes.createBranch(newName) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Créée depuis la position actuelle (HEAD).")
        }
        .confirmationDialog("Valider les modifications pour changer de branche ?",
                            isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } }),
                            titleVisibility: .visible, presenting: blocked) { target in
            Button("Valider et changer de branche") {
                change { await changes.commitAndSwitch(to: target.branch, message: "") }
            }
            Button("Annuler", role: .cancel) {}
        } message: { target in
            Text(blockedMessage(target.paths))
        }
    }

    private var label: String {
        guard let summary = changes.summary else { return "Branche" }
        return summary.headRefType == "detached" ? "HEAD détachée" : (summary.branchName ?? "Branche")
    }

    private func blockedMessage(_ paths: [String]) -> String {
        let shown = paths.prefix(5).joined(separator: "\n")
        let more = paths.count > 5 ? "\n… et \(paths.count - 5) autres" : ""
        return "Ces fichiers seraient écrasés :\n\(shown)\(more)\n\nToutes les modifications seront validées (« chore: checkpoint… »), puis la bascule reprendra."
    }

    private func change(_ action: @escaping () async -> BranchOutcome) {
        Task {
            if case .needsCommit(let branch, let paths) = await action() { blocked = (branch, paths) }
        }
    }
}
