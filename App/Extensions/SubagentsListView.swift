import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Liste des sous-agents d'une portée : personnalisés, plugins, intégrés. Hors ligne, la liste lue reste affichée en
/// lecture seule.
struct SubagentsListView: View {
    let model: SubagentsModel
    let host: Host
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var pendingDelete: AgentSummary?
    @State private var creating = false

    var body: some View {
        let sections = model.sections(query: query)
        let catalog = app.modelCatalog(for: host).view
        List {
            statusSection
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.agents) { agent in
                        row(agent, catalog: catalog)
                    }
                }
            }
            if let notice = model.notice {
                Section { SubagentNoticeLabel(text: notice) }
            }
        }
        .accessibilityIdentifier("subagents-list")
        .searchable(text: $query, prompt: "Rechercher un sous-agent")
        .overlay { overlay(sections) }
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Nouveau sous-agent", systemImage: "plus") { creating = true }
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier("subagent-new")
            }
        }
        .sheet(isPresented: $creating) {
            SubagentEditorView(host: host, model: model, editing: nil)
        }
        .subagentActionAlert(model, suppressed: creating)
        .deleteSubagentConfirmation(for: $pendingDelete) { agent in
            Task { await model.delete(agent) }
        }
    }

    // MARK: - États

    @ViewBuilder private var statusSection: some View {
        // Portée Utilisateur que l'hôte n'offre pas (`capability.userScopeAvailable`) : création désactivée, comme le web.
        if let unavailable = model.userScopeUnavailable {
            Section {
                Label(unavailable, systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)
            }
        }
        if case .failed(let message) = model.phase {
            Section {
                if model.list == nil {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("subagents-error")
                } else {
                    SubagentOfflineBanner(offline: model.isOffline, message: message)
                }
                Button("Réessayer") { Task { await model.refresh() } }
            }
        }
    }

    @ViewBuilder private func overlay(_ sections: [SubagentSection]) -> some View {
        if model.list == nil {
            if model.phase == .idle || model.phase == .loading {
                ProgressView("Chargement des sous-agents…")
            }
        } else if model.list != nil, sections.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView("Aucun sous-agent", systemImage: "person.2",
                                       description: Text("Aucun sous-agent dans cette portée."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    // MARK: - Ligne

    private func row(_ agent: AgentSummary, catalog: ModelSelectionView?) -> some View {
        NavigationLink {
            SubagentDetailView(model: model, host: host, fallback: agent)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if let color = agent.color {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(AgentColors.swiftUI(color))
                        .padding(.top, 5)
                        .accessibilityLabel("Couleur : \(ExtensionsLabels.color(color))")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.headline)
                    if !agent.description.isEmpty {
                        Text(SubagentForm.displayDescription(of: agent))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    // Côte à côte s'ils tiennent, sinon l'un sous l'autre (grandes tailles de texte).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { badges(agent, catalog: catalog) }
                        VStack(alignment: .leading, spacing: 4) { badges(agent, catalog: catalog) }
                    }
                }
                if agent.canToggleEnabled {
                    Spacer(minLength: 8)
                    Toggle("Activé", isOn: Binding(
                        get: { agent.enabled },
                        set: { enabled in Task { await model.setEnabled(agent, enabled) } }
                    ))
                    .labelsHidden()
                    .disabled(model.isReadOnly || model.busy)
                    .accessibilityLabel("Activer \(agent.name)")
                    .accessibilityIdentifier("subagent-enabled-\(agent.name)")
                }
            }
        }
        .accessibilityIdentifier("subagent-row-\(agent.name)")
        .swipeActions {
            if agent.isEditable, !model.isReadOnly {
                Button("Supprimer", role: .destructive) { pendingDelete = agent }
                    .accessibilityIdentifier("subagent-delete")
            }
        }
    }

    /// Badges d'une ligne : modèle (agent personnalisé qui en impose un), puis outils.
    @ViewBuilder private func badges(_ agent: AgentSummary, catalog: ModelSelectionView?) -> some View {
        if agent.source == .user, let selection = agent.modelSelection {
            Badge(text: ExtensionsLabels.model(selection, catalog: catalog, inherit: ""), systemImage: "cpu")
        }
        Badge(text: ExtensionsLabels.tools(agent.tools), systemImage: "wrench.and.screwdriver")
    }
}

/// Pastille de texte (modèle, outils, plugins) lue telle quelle par VoiceOver.
struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

enum AgentColors {
    /// Couleur d'affichage ; une couleur inconnue de l'app reste neutre (son nom est lu par VoiceOver).
    static func swiftUI(_ color: ZCodeV4.AgentColor) -> Color {
        switch color {
        case .yellow: .yellow
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        default: .secondary
        }
    }
}

extension View {
    /// Confirmation de suppression, commune à la liste et au détail.
    func deleteSubagentConfirmation(for agent: Binding<AgentSummary?>, confirm: @escaping (AgentSummary) -> Void) -> some View {
        confirmationDialog(
            "Supprimer le sous-agent « \(agent.wrappedValue?.name ?? "") » ?",
            isPresented: Binding(get: { agent.wrappedValue != nil }, set: { if !$0 { agent.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: agent.wrappedValue
        ) { target in
            Button("Supprimer", role: .destructive) { confirm(target) }
        } message: { _ in
            Text("Cette action est irréversible.")
        }
    }
}
