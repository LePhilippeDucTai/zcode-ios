import SwiftUI
import ZCodeAppCore

/// Explorateur de dossiers de l'hôte pour ajouter un projet (lot 13H) : part du home, ne propose que les
/// dossiers, « Choisir ce dossier » ajoute le dossier courant. Toute la logique est dans `ProjectPickerModel`.
struct ProjectPickerView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picker: ProjectPickerModel
    @State private var workspaceError: String?

    init(host: Host, connection: HostConnection) {
        self.host = host
        _picker = State(initialValue: ProjectPickerModel(connection: connection))
    }

    var body: some View {
        NavigationStack {
            List {
                switch picker.listing {
                case .loading:
                    EmptyView()
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Réessayer") { Task { await picker.reload() } }
                        .accessibilityIdentifier("project-retry")
                case .loaded(let entries):
                    ForEach(entries) { entry in
                        Button {
                            Task { await picker.descend(entry) }
                        } label: {
                            Label {
                                Text(entry.name) + Text(entry.isSymbolicLink ? " ↗" : "").foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .accessibilityIdentifier("project-entry-\(entry.name)")
                    }
                }
            }
            .accessibilityIdentifier("project-picker-list")
            .overlay {
                switch picker.listing {
                case .loading:
                    ProgressView()
                case .loaded([]):
                    ContentUnavailableView("Dossier vide", systemImage: "folder")
                case .loaded:
                    EmptyView()
                case .failed:
                    EmptyView()
                }
            }
            .navigationTitle("Ajouter un projet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choisir ce dossier") { choose() }
                        .disabled(picker.listing == .loading)
                        .accessibilityIdentifier("project-choose")
                }
            }
            // Barre du bas hors `.toolbar` : la toolbar iOS 26 filtre le texte décoratif de l'arbre
            // d'accessibilité (le chemin devenait invisible aux tests et à VoiceOver).
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        Task { await picker.goUp() }
                    } label: {
                        Label("Remonter", systemImage: "arrow.up")
                    }
                    .disabled(!picker.canGoUp)
                    .accessibilityIdentifier("project-up")
                    Spacer()
                    Text(picker.currentPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .accessibilityIdentifier("project-path")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .task { await picker.start() }
        }
        .accessibilityIdentifier("project-picker")
        .alert("Projet refusé", isPresented: Binding(get: { workspaceError != nil },
                                                   set: { if !$0 { workspaceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceError ?? "")
        }
    }

    private func choose() {
        do {
            try model.hostStore.addWorkspace(picker.currentPath, to: host.id)
            model.refreshHost(host.id)
            dismiss()
        } catch let validation as HostValidationError {
            workspaceError = validation.message
        } catch {
            workspaceError = error.localizedDescription
        }
    }
}
