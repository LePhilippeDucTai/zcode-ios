import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Modifications Git du projet, en quatre sections ; un fichier ouvre son diff. Actions : balayer pour indexer ou
/// annuler (confirmation), valider, pousser, changer de branche.
struct WorkspaceChangesView: View {
    let host: Host
    let workspace: String
    @Environment(AppModel.self) private var model
    @State private var committing = false
    @State private var pendingDiscard: GitFileChange?

    var body: some View {
        let changes = model.workspaceChanges(for: host, workspace: workspace)
        List {
            if let summary = changes.summary, summary.isRepository {
                Section {
                    Label(branchLabel(summary), systemImage: "arrow.triangle.branch").font(.callout)
                }
            }
            if case .failed(let reason) = changes.phase {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Réessayer") { Task { await changes.refresh() } }
                }
            }
            section("Indexées", changes.staged, changes)
            section("Non indexées", changes.unstaged, changes, stageAll: changes.unstaged + changes.untracked)
            section("Non suivies", changes.untracked, changes,
                    footer: "Supprimer un fichier non suivi : demande-le à l'agent.")
            section("En conflit", changes.conflicted, changes)
        }
        .accessibilityIdentifier("changes-list")
        .overlay {
            switch changes.phase {
            case .idle, .loading:
                if changes.summary == nil { ProgressView("Lecture du dépôt…") }
            case .notRepository:
                ContentUnavailableView("Pas un dépôt Git", systemImage: "arrow.triangle.branch", description: Text(
                    changes.summary?.isGitAvailable == false ? "Git est absent de l'hôte." : "Ce projet n'est pas dans un dépôt Git."))
            case .ready:
                if changes.isEmpty { ContentUnavailableView("Aucune modification", systemImage: "checkmark.circle") }
            case .failed:
                EmptyView()
            }
        }
        .navigationTitle("Modifications")
        .toolbar {
            if changes.phase == .ready {
                ToolbarItem(placement: .primaryAction) { BranchMenu(changes: changes) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if changes.phase == .ready { actionBar(changes) }
        }
        .sheet(isPresented: $committing) { CommitSheet(changes: changes) }
        .confirmationDialog(pendingDiscard.map { "Annuler les modifications de \(URL(filePath: $0.path).lastPathComponent) ?" } ?? "",
                            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            titleVisibility: .visible, presenting: pendingDiscard) { change in
            Button("Annuler les modifications", role: .destructive) { Task { await changes.discard(change) } }
            Button("Garder", role: .cancel) {}
        } message: { change in
            Text("Irréversible : le fichier revient à son état \(change.isStaged ? "du dernier commit" : "indexé").")
        }
        .task { await changes.refresh() }
        .refreshable { await changes.refresh() }
    }

    /// Valider / pousser, et le dernier message (succès 3 s, erreur jusqu'à fermeture).
    private func actionBar(_ changes: WorkspaceChangesModel) -> some View {
        VStack(spacing: 8) {
            if let error = changes.actionError {
                HStack(alignment: .top) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = error }.labelStyle(.iconOnly)
                    Button("Fermer", systemImage: "xmark") { changes.dismissActionMessages() }.labelStyle(.iconOnly)
                }
                .padding(10)
                .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("git-action-error")
            } else if let notice = changes.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("git-notice")
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if changes.notice == notice { changes.dismissActionMessages() }
                    }
            }
            HStack(spacing: 12) {
                Button { committing = true } label: {
                    Label("Valider…", systemImage: "checkmark.seal").frame(maxWidth: .infinity)
                }
                .disabled(changes.isEmpty || changes.staged.isEmpty && changes.unstaged.isEmpty && changes.untracked.isEmpty)
                .accessibilityIdentifier("git-commit")
                Button { Task { await changes.push() } } label: {
                    Group {
                        if changes.action == .push { ProgressView() } else { Label(pushLabel(changes), systemImage: "arrow.up.circle") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!changes.canPush)
                .accessibilityIdentifier("git-push")
            }
            .buttonStyle(.bordered)
            .disabled(changes.action != nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func pushLabel(_ changes: WorkspaceChangesModel) -> String {
        guard let summary = changes.summary else { return "Pousser" }
        if summary.trackingBranchName == nil { return "Publier" }
        return summary.ahead > 0 ? "Pousser (\(summary.ahead))" : "Pousser"
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitFileChange], _ changes: WorkspaceChangesModel,
                         stageAll: [GitFileChange]? = nil, footer: String? = nil) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { change in
                    NavigationLink(value: GitDiffRoute(hostId: host.id, workspace: workspace, change: change)) {
                        GitChangeRow(change: change)
                    }
                    .disabled(change.isDirectory)
                    .accessibilityIdentifier("change-\(change.workspaceRelativePath)")
                    .swipeActions(edge: .leading) {
                        if change.isStaged {
                            Button("Retirer de l'index", systemImage: "minus.circle") { Task { await changes.unstage([change]) } }
                                .accessibilityIdentifier("git-unstage-\(change.workspaceRelativePath)")
                        } else if !change.isConflicted {
                            Button("Indexer", systemImage: "plus.circle") { Task { await changes.stage([change]) } }
                                .tint(.green)
                                .accessibilityIdentifier("git-stage-\(change.workspaceRelativePath)")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if changes.canDiscard(change) {
                            Button("Annuler les modifications", systemImage: "arrow.uturn.backward", role: .destructive) {
                                pendingDiscard = change
                            }
                            .accessibilityIdentifier("git-discard-\(change.workspaceRelativePath)")
                        }
                    }
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    if let stageAll, !stageAll.isEmpty {
                        Button("Tout indexer") { Task { await changes.stage(stageAll) } }
                            .font(.caption)
                            .disabled(changes.action != nil)
                            .accessibilityIdentifier("git-stage-all")
                    }
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func branchLabel(_ summary: GitRepositorySummary) -> String {
        var label = summary.headRefType == "detached" ? "HEAD détachée" : (summary.branchName ?? "Branche inconnue")
        if summary.ahead > 0 { label += " · \(summary.ahead) en avance" }
        if summary.behind > 0 { label += " · \(summary.behind) en retard" }
        return label
    }
}

private struct GitChangeRow: View {
    let change: GitFileChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.workspaceRelativePath).font(.callout.monospaced()).lineLimit(2).truncationMode(.head)
                Text(change.isConflicted ? "En conflit" : change.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if change.added > 0 { Text("+\(change.added)").font(.caption.monospaced()).foregroundStyle(.green) }
            if change.removed > 0 { Text("−\(change.removed)").font(.caption.monospaced()).foregroundStyle(.red) }
        }
    }

    private var icon: String {
        if change.isConflicted { return "exclamationmark.triangle.fill" }
        switch change.kind {
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    private var color: Color {
        if change.isConflicted { return .red }
        switch change.kind {
        case .added: return .green
        case .deleted: return .red
        default: return .orange
        }
    }
}

/// Diff d'un fichier modifié, lu à l'ouverture.
struct GitDiffView: View {
    let host: Host
    let route: GitDiffRoute
    @Environment(AppModel.self) private var model
    @State private var load: DiffLoad?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch load {
                case nil:
                    ProgressView().frame(maxWidth: .infinity)
                case .unavailable(let reason)?:
                    Label(reason, systemImage: "doc.questionmark").foregroundStyle(.secondary)
                case .loaded(let files)?:
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        DiffView(file: file, maxLines: 3_000)
                    }
                }
                if route.change.kind != .deleted, !route.change.isDirectory {
                    NavigationLink(value: FileRoute(hostId: host.id, workspace: route.workspace, path: route.change.path)) {
                        Label("Ouvrir le fichier", systemImage: "doc.text")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(URL(filePath: route.change.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { load = await model.workspaceChanges(for: host, workspace: route.workspace).diff(for: route.change) }
    }
}
