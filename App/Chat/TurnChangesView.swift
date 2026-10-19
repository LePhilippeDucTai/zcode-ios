import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Fichiers modifiés par un tour (`conversationFileChangesV4`) ; un fichier ouvre son diff, puis le fichier lui-même.
struct TurnChangesView: View {
    let conversation: ConversationModel
    let host: Host
    let workspace: String
    let target: RowTarget
    @Environment(\.dismiss) private var dismiss
    @State private var load: TurnChangesLoad?

    var body: some View {
        NavigationStack {
            Group {
                switch load {
                case nil:
                    ProgressView("Chargement des fichiers modifiés…")
                case .failed(let reason)?:
                    ContentUnavailableView {
                        Label("Fichiers indisponibles", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason)
                    } actions: {
                        Button("Réessayer") { Task { await reload() } }
                    }
                case .loaded(let changes)?:
                    List {
                        if changes.state == "reverted" {
                            Label("Modifications annulées depuis ce tour", systemImage: "arrow.uturn.backward")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(changes.items, id: \.path) { item in
                            NavigationLink(value: item) {
                                VStack(alignment: .leading, spacing: 2) {
                                    DiffStatsLabel(path: WorkspacePaths.display(item.path, in: workspace),
                                                   additions: item.additions, deletions: item.deletions)
                                    if !item.toolNames.isEmpty {
                                        Text(item.toolNames.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("turn-changes-list")
                    .overlay {
                        if changes.items.isEmpty {
                            ContentUnavailableView("Détail indisponible", systemImage: "doc.questionmark",
                                                   description: Text("L'hôte ne donne pas la liste des fichiers de ce tour."))
                        }
                    }
                }
            }
            .navigationTitle("Fichiers modifiés")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FileChangeItem.self) { item in
                TurnFileDiffView(host: host, workspace: workspace, item: item)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .task { if load == nil { await reload() } }
        }
    }

    private func reload() async {
        load = nil
        load = await conversation.fileChanges(for: target)
    }
}

/// Diff d'un fichier du tour (hunks de l'hôte, numéros réels) et accès au fichier.
private struct TurnFileDiffView: View {
    let host: Host
    let workspace: String
    let item: FileChangeItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DiffStatsLabel(path: WorkspacePaths.display(item.path, in: workspace),
                               additions: item.additions, deletions: item.deletions)
                if item.patches.isEmpty {
                    Label("Diff indisponible pour ce fichier.", systemImage: "doc.questionmark").foregroundStyle(.secondary)
                } else {
                    DiffView(file: UnifiedDiff.file(path: item.path, hunks: item.patches), maxLines: 3_000)
                }
                NavigationLink {
                    FileView(host: host, workspace: workspace, path: item.path)
                } label: {
                    Label("Ouvrir le fichier", systemImage: "doc.text")
                }
            }
            .padding()
        }
        .navigationTitle(URL(filePath: item.path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}
