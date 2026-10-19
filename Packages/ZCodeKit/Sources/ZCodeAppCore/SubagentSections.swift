import Foundation
import ZCodeV4

/// Groupe de sous-agents de la liste : personnalisés, un groupe par plugin, intégrés.
public struct SubagentSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case custom
        case plugin(id: String, name: String)
        case builtIn
    }

    public let kind: Kind
    public let agents: [AgentSummary]

    public init(kind: Kind, agents: [AgentSummary]) {
        self.kind = kind
        self.agents = agents
    }

    public var id: String {
        switch kind {
        case .custom: "custom"
        case .plugin(let id, _): "plugin:\(id)"
        case .builtIn: "built-in"
        }
    }

    public var title: String {
        switch kind {
        case .custom: "Personnalisés"
        case .plugin(_, let name): name
        case .builtIn: "Intégrés"
        }
    }
}

/// Regroupement de la liste de l'hôte selon la portée choisie (règles de `SubagentsSection.tsx` de ZCode Web).
public enum SubagentSections {
    /// - Utilisateur : agents de l'utilisateur, groupes de plugins de portée utilisateur, intégrés.
    /// - Projet `p` : agents et groupes de plugins de ce projet seulement, jamais d'intégrés.
    ///
    /// Triés par nom ; la recherche porte sur le nom et la description, sans casse ni accents ; groupes vides retirés.
    public static func make(_ list: AgentsListResult, scope: ExtensionScope, query: String) -> [SubagentSection] {
        let needle = SessionListLayout.normalized(query)
        func keep(_ agent: AgentSummary) -> Bool {
            needle.isEmpty
                || SessionListLayout.normalized(agent.name).contains(needle)
                || SessionListLayout.normalized(agent.description).contains(needle)
        }
        func sorted(_ agents: [AgentSummary]) -> [AgentSummary] {
            agents.filter(keep).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let custom: [AgentSummary]
        let plugins: [AgentSummary]
        var builtIn: [AgentSummary] = []
        switch scope {
        case .user:
            custom = list.userAgents.filter { $0.scope == .user }
            plugins = list.pluginAgents.filter { $0.scope == .user }
            builtIn = list.agents.filter { $0.source == .builtIn }
        case .workspace(let path):
            custom = list.userAgents.filter { $0.scope == .workspace && $0.projectPath == path }
            plugins = list.pluginAgents.filter { $0.scope == .workspace && $0.projectPath == path }
        }

        var sections: [SubagentSection] = []
        let customAgents = sorted(custom)
        if !customAgents.isEmpty { sections.append(SubagentSection(kind: .custom, agents: customAgents)) }

        var byPlugin: [String: [AgentSummary]] = [:]
        for agent in plugins { byPlugin[agent.pluginId ?? agent.id, default: []].append(agent) }
        let groups: [SubagentSection] = byPlugin.compactMap { id, agents in
            let kept = sorted(agents)
            guard let first = kept.first else { return nil }
            return SubagentSection(kind: .plugin(id: id, name: first.pluginName ?? id), agents: kept)
        }
        sections += groups.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let builtInAgents = sorted(builtIn)
        if !builtInAgents.isEmpty { sections.append(SubagentSection(kind: .builtIn, agents: builtInAgents)) }
        return sections
    }
}
