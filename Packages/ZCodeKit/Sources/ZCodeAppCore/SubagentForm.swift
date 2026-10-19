import Foundation
import ZCodeV4

/// Défaut d'un formulaire de sous-agent : mêmes règles que ZCode Web (et que l'hôte, qui les rejette à l'écriture).
public enum SubagentFormIssue: Equatable, Sendable {
    case nameLength
    case nameCharacters
    case nameReserved
    case nameTaken
    case descriptionMissing
    case systemPromptMissing
    case toolsEmpty
    case modelUnavailable
    case effortUnsupported
    case maxTurnsInvalid

    public var message: String {
        switch self {
        case .nameLength: ExtensionsLabels.nameLength
        case .nameCharacters: ExtensionsLabels.nameCharacters
        case .nameReserved: ExtensionsLabels.nameReserved
        case .nameTaken: ExtensionsLabels.nameTaken
        case .descriptionMissing: ExtensionsLabels.descriptionRequired
        case .systemPromptMissing: ExtensionsLabels.instructionsRequired
        case .toolsEmpty: ExtensionsLabels.toolsRequired
        case .modelUnavailable: ExtensionsLabels.modelUnavailable
        case .effortUnsupported: ExtensionsLabels.effortUnsupported
        case .maxTurnsInvalid: ExtensionsLabels.maxTurnsInvalid
        }
    }
}

/// Formulaire de création ou de modification d'un sous-agent. Il édite ce que ZCode Web édite, plus les champs avancés que
/// le runtime honore (outils interdits, compétences, tours maximum, arrière-plan, mode d'autorisation). Les serveurs MCP
/// et tout ce qu'il ne montre pas sont repris tels quels de l'agent lu, car l'hôte réécrit le fichier entier.
public struct SubagentForm: Equatable, Sendable {
    // Texte
    public var name = ""
    public var description = ""
    public var systemPrompt = ""

    // Réglages
    public var color: AgentColor = .yellow
    public var modelSelection: ModelSelection?
    public var injectAgentsMd = true

    // Outils : « Tous » (clé omise) ou une liste. Les entrées inconnues de l'app (`Bash(git diff *)`, outils MCP…) sont
    // gardées dans leur ordre d'origine.
    public var allTools = true
    public var selectedTools: Set<String> = []
    public var extraTools: [String] = []

    // Avancé
    /// Outils interdits : les connus cochés, puis les entrées inconnues (`Bash(rm *)`, outils MCP…) dans leur ordre.
    public var disallowedTools: Set<String> = []
    public var extraDisallowedTools: [String] = []
    /// Compétences, une par ligne ou séparées par des virgules.
    public var skillsText = ""
    /// Tours maximum ; vide = pas de limite.
    public var maxTurnsText = ""
    public var background = false
    /// `nil` = « Défaut ». Seulement envoyé en portée Utilisateur : le runtime l'ignore pour un agent de projet.
    public var permissionMode: AgentPermissionMode?

    /// Le mode d'autorisation ne s'applique qu'aux agents de la portée Utilisateur.
    public var permissionModeEditable: Bool { scope == .user }

    /// Outils proposés par ZCode Web (`TOOL_OPTIONS`) : l'hôte n'en publie pas la liste.
    public static let knownTools = ["Read", "Grep", "Glob", "Bash", "Edit", "Write", "WebFetch", "WebSearch", "TodoWrite"]
    /// Outils qui modifient l'hôte, signalés dans le formulaire.
    public static let riskyTools: Set<String> = ["Bash", "Edit", "Write"]
    /// Noms que l'hôte refuse (égalité exacte, comme lui : `explore` en minuscules passe).
    private static let reservedNames: Set<String> = ["general-purpose", "Explore"]

    /// Portée du modèle qui enregistre ; la modification des champs avancés s'en sert.
    public let scope: ExtensionScope

    /// Création.
    public init(scope: ExtensionScope) {
        self.scope = scope
    }

    /// Modification de `agent`, tel que l'hôte le renvoie.
    public init(editing agent: AgentSummary, scope: ExtensionScope) {
        self.scope = scope
        name = agent.name
        description = Self.displayDescription(of: agent)
        systemPrompt = agent.systemPrompt
        color = agent.color ?? .yellow
        modelSelection = agent.modelSelection
        injectAgentsMd = agent.injectAgentsMd ?? true
        if let tools = agent.tools, !Self.meansAllTools(tools) {
            allTools = false
            selectedTools = Set(tools.filter(Self.knownTools.contains))
            extraTools = tools.filter { !Self.knownTools.contains($0) }
        }
        let denied = agent.disallowedTools ?? []
        disallowedTools = Set(denied.filter(Self.knownTools.contains))
        extraDisallowedTools = denied.filter { !Self.knownTools.contains($0) }
        skillsText = (agent.skills ?? []).joined(separator: "\n")
        maxTurnsText = agent.maxTurns.map(String.init) ?? ""
        background = agent.background ?? false
        permissionMode = agent.permissionMode
    }

    /// Absence de liste, liste vide ou joker `*` : tous les outils.
    private static func meansAllTools(_ tools: [String]) -> Bool {
        tools.isEmpty || tools.contains("*")
    }

    /// Contournement de l'hôte 3.15.1 : il échappe `"` et `\` de la description à l'écriture sans les rendre à la
    /// lecture (`Description avec "x" et \ y` revient `Description avec \"x\" et \\ y`), si bien que chaque
    /// enregistrement ajouterait des barres. La description lue est donc déséchappée, en un seul passage de gauche à
    /// droite : `\"` devient `"`, `\\` devient `\`, toute autre barre reste telle quelle. À appliquer à toute
    /// description d'un agent de l'hôte, en édition comme à l'affichage.
    public static func hostDescription(_ read: String) -> String {
        var result = ""
        var iterator = read.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let next = iterator.next() else { result.append(character); break }
            if next == "\"" || next == "\\" {
                result.append(next)
            } else {
                result.append(character)
                result.append(next)
            }
        }
        return result
    }

    /// Description d'un agent de l'hôte, prête à afficher ou à éditer : déséchappée seulement pour un agent que l'hôte a
    /// écrit depuis une configuration (`source == user`) ; un intégré ou un agent de plugin n'a jamais été échappé.
    public static func displayDescription(of agent: AgentSummary) -> String {
        agent.source == .user ? hostDescription(agent.description) : agent.description
    }

    /// Choix d'un modèle : l'effort le plus fort qu'il propose, aucun s'il n'en propose pas.
    public mutating func selectModel(providerId: String, model: ModelSelectionView.Model) {
        modelSelection = ModelChoice.selecting(providerId: providerId, model: model)
    }

    // MARK: - Validation

    /// Défauts empêchant l'enregistrement, dans l'ordre du formulaire. `existing` : les agents modifiables de la portée ;
    /// `editing` : l'agent en cours de modification, exclu du contrôle de doublon. Le modèle et l'effort ne sont contrôlés
    /// qu'une fois le catalogue de l'hôte chargé.
    public func issues(existing: [AgentSummary], editing: AgentSummary?, catalog: ModelSelectionView?) -> [SubagentFormIssue] {
        var issues: [SubagentFormIssue] = []
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Longueur comptée comme `String.length` de JavaScript, pour rester d'accord avec l'hôte.
        if !(3...50).contains(name.utf16.count) {
            issues.append(.nameLength)
        } else if !name.unicodeScalars.allSatisfy(Self.isNameScalar) {
            issues.append(.nameCharacters)
        } else if Self.reservedNames.contains(name) {
            issues.append(.nameReserved)
        } else {
            let lowered = name.lowercased()
            let taken = existing.contains { other in
                guard other.name.lowercased() == lowered else { return false }
                guard let editing else { return true }
                return !(other.id == editing.id && other.path == editing.path)
            }
            if taken { issues.append(.nameTaken) }
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.descriptionMissing) }
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.systemPromptMissing) }
        if !allTools, selectedTools.isEmpty, extraTools.isEmpty { issues.append(.toolsEmpty) }
        if let catalog, let selection = modelSelection {
            if !ModelChoice.isAvailable(selection, in: catalog) {
                issues.append(.modelUnavailable)
            } else if !ModelChoice.supportsEffort(selection, in: catalog) {
                issues.append(.effortUnsupported)
            }
        }
        if parsedMaxTurns == nil, !trimmedMaxTurns.isEmpty { issues.append(.maxTurnsInvalid) }
        return issues
    }

    private var trimmedMaxTurns: String { maxTurnsText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Entier strictement positif ; `nil` si le texte est vide ou invalide.
    private var parsedMaxTurns: Int? {
        Int(trimmedMaxTurns).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Compétences nettoyées : une par ligne ou séparées par des virgules, vides et doublons retirés (ordre gardé).
    private var parsedSkills: [String] {
        var seen: Set<String> = []
        return skillsText.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-": true
        default: false
        }
    }

    // MARK: - Configuration envoyée

    /// Définition à envoyer à l'hôte. `agent` : l'agent modifié (`nil` en création), dont les champs que le formulaire
    /// ne montre pas sont repris tels quels.
    public func config(basedOn agent: AgentSummary?) -> SubAgentConfig {
        var config = SubAgentConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        config.color = color
        config.injectAgentsMd = injectAgentsMd
        config.modelSelection = modelSelection
        if allTools {
            // « Tous » s'écrit comme l'hôte l'avait écrit (`["*"]` reste `["*"]`), sinon la clé est omise.
            if let old = agent?.tools, Self.meansAllTools(old) { config.tools = old }
        } else {
            config.tools = Self.knownTools.filter(selectedTools.contains) + extraTools
        }
        let denied = Self.knownTools.filter(disallowedTools.contains) + extraDisallowedTools
        config.disallowedTools = denied.isEmpty ? nil : denied
        let skills = parsedSkills
        config.skills = skills.isEmpty ? nil : skills
        config.maxTurns = parsedMaxTurns
        // Décocher n'écrit `false` que si l'agent portait déjà la clé.
        config.background = background ? true : (agent?.background == nil ? nil : false)
        // Le runtime ignore le mode d'un agent de projet : celui de l'agent reste intact.
        config.permissionMode = permissionModeEditable ? permissionMode : agent?.permissionMode
        config.mcpServers = agent?.mcpServers
        return config
    }
}
