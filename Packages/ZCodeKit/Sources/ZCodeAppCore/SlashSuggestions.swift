import Foundation
import ZCodeV4

/// Une ligne du panneau « / » : commande de l'hôte, skill ou sous-agent.
public struct SlashEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case command, skill, subagent
    }

    public let kind: Kind
    /// Nom sans préfixe (`goal`, `review-agent`, `Explore`) : suffixe de l'identifiant d'accessibilité.
    public let name: String
    /// Ce que le panneau affiche en tête de ligne et ce que le toucher insère : `/nom`, `$nom` ou `@nom`.
    public let insertion: String
    /// Usage d'une commande (`inputHint`) quand il dit plus que `/nom`.
    public let hint: String?
    /// Description brute (filtrage).
    public let description: String
    /// Ligne secondaire : provenance et description (skills, sous-agents), note de `/compact`.
    public let detail: String
    /// Texte envoyé à la place du jeton resté intact : lien d'une skill, `@nom` d'un sous-agent ; `nil` pour une commande
    /// (envoyée telle quelle, l'hôte la développe).
    public let sendAs: String?

    public var id: String { "\(kind.rawValue)-\(name)" }
}

public struct SlashSection: Identifiable, Equatable, Sendable {
    public let kind: SlashEntry.Kind
    public let entries: [SlashEntry]

    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .command: "Commandes"
        case .skill: "Skills"
        case .subagent: "Sous-agents"
        }
    }
}

/// Règles du panneau « / » de ZCode Web (`slashCommandHelpers.ts`, `skillsMentionProvider.ts`,
/// `subagentsMentionProvider.ts`, `skillSourceFilter.ts`) : rien n'est ajouté à ce que l'hôte publie.
public enum SlashSuggestions {
    /// Commandes de l'hôte, dans son ordre.
    public static func commands(_ commands: [SlashCommandInfo]) -> [SlashEntry] {
        var seen = Set<String>()
        return commands.compactMap { command in
            let name = normalizedCommandName(command.name)
            // Un seul exemplaire par nom (« init » et « /init » : même identifiant), le premier de l'hôte est gardé.
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let hint = command.inputHint?.trimmingCharacters(in: .whitespaces)
            let isCompact = ["compact", "compress"].contains(name.lowercased())
            let detail = [command.description, isCompact ? "Le texte qui suit /\(name) est ignoré." : ""].filter { !$0.isEmpty }.joined(separator: " ")
            return SlashEntry(kind: .command, name: name, insertion: "/" + name,
                              hint: hint.flatMap { $0.isEmpty || $0 == "/" + name ? nil : $0 },
                              description: command.description, detail: detail, sendAs: nil)
        }
    }

    /// `normalizeSlashCommandValue` : l'hôte peut renvoyer « /init ».
    static func normalizedCommandName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).drop { $0 == "/" }).trimmingCharacters(in: .whitespaces)
    }

    /// Skills activées et de ZCode, une par nom : projet, puis plugin, puis utilisateur.
    public static func skills(_ skills: [SkillReference]) -> [SlashEntry] {
        let candidates = skills.filter { $0.enabled && isZCodeSkill($0) }
        let kept = deduplicated(candidates, name: \.name) { skill in
            switch skill.scope {
            case .workspace: 0
            case .plugin: 1
            case .user: 2
            default: 3
            }
        }
        return kept.map { skill in
            let source: String = switch skill.scope {
            case .workspace: "Projet"
            case .user: "Utilisateur"
            case .plugin: "Plugin"
            default: skill.scope.rawValue
            }
            return SlashEntry(kind: .skill, name: skill.name, insertion: "$" + skill.name, hint: nil,
                              description: skill.description, detail: detail(source, skill.description),
                              sendAs: SlashMarkdown.skill(name: skill.name, path: skill.path))
        }
    }

    /// Sous-agents activés du runtime, un par nom : projet, puis utilisateur, puis le reste (plugins, intégrés).
    public static func subagents(_ agents: [AgentSummary]) -> [SlashEntry] {
        let candidates = agents.filter { $0.enabled && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let kept = deduplicated(candidates, name: \.name) { agent in
            agent.scope == .workspace ? 0 : agent.source == .user ? 1 : 2
        }
        return kept.map { agent in
            let source = agent.scope == .workspace ? "Projet"
                : agent.source == .plugin ? "Plugin" : agent.source == .builtIn ? "Intégré" : "Utilisateur"
            return SlashEntry(kind: .subagent, name: agent.name, insertion: "@" + agent.name, hint: nil,
                              description: agent.description, detail: detail(source, agent.description),
                              sendAs: SlashMarkdown.subagent(name: agent.name))
        }
    }

    /// `isZcodeSkill` du web : skill de plugin, identifiant `glm:…`, ou rangée sous `.zcode/skills/` ou le cache des plugins
    /// (sans chemin, seuls les deux premiers critères peuvent la rendre « de ZCode »).
    public static func isZCodeSkill(_ skill: SkillReference) -> Bool {
        if skill.scope == .plugin || skill.id.hasPrefix("glm:") { return true }
        guard let rawPath = skill.path else { return false }      // sans chemin : seuls la portée plugin et `glm:` comptent
        let path = rawPath.replacingOccurrences(of: "\\", with: "/").lowercased()
        return path.contains("/.zcode/skills/") || path.contains("/.zcode/cli/plugins/cache/")
    }

    /// Texte tapé après « / », sans casse ni accents : nom qui commence par le texte, nom qui le contient, puis
    /// description qui le contient ; l'ordre de l'hôte départage. Texte vide : tout, dans l'ordre.
    public static func filter(_ entries: [SlashEntry], query: String) -> [SlashEntry] {
        let needle = SessionListLayout.normalized(query)
        guard !needle.isEmpty else { return entries }
        func rank(_ entry: SlashEntry) -> Int? {
            let name = SessionListLayout.normalized(entry.name)
            if name.hasPrefix(needle) { return 0 }
            if name.contains(needle) { return 1 }
            return SessionListLayout.normalized(entry.description).contains(needle) ? 2 : nil
        }
        return entries.enumerated()
            .compactMap { item in rank(item.element).map { (rank: $0, index: item.offset, entry: item.element) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.entry)
    }

    /// Sections non vides, dans l'ordre Commandes, Skills, Sous-agents ; une source `nil` (jamais lue ou en échec) n'en a pas.
    public static func sections(commands: [SlashEntry]?, skills: [SlashEntry]?, subagents: [SlashEntry]?,
                                query: String) -> [SlashSection] {
        let sources: [(SlashEntry.Kind, [SlashEntry]?)] = [(.command, commands), (.skill, skills), (.subagent, subagents)]
        return sources.compactMap { kind, entries in
            guard let entries else { return nil }
            let kept = filter(entries, query: query)
            return kept.isEmpty ? nil : SlashSection(kind: kind, entries: kept)
        }
    }

    private static func detail(_ source: String, _ description: String) -> String {
        description.isEmpty ? source : "\(source) · \(description)"
    }

    /// Une entrée par nom (sans casse, espaces de bord retirés) : la plus prioritaire, à la place de la première vue.
    private static func deduplicated<T>(_ items: [T], name: KeyPath<T, String>, priority: (T) -> Int) -> [T] {
        var order: [String] = []
        var kept: [String: T] = [:]
        for item in items {
            let key = item[keyPath: name].trimmingCharacters(in: .whitespaces).lowercased()
            if let current = kept[key] {
                if priority(item) < priority(current) { kept[key] = item }
            } else {
                order.append(key)
                kept[key] = item
            }
        }
        return order.compactMap { kept[$0] }
    }
}
