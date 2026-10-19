import Foundation
import ZCodeWire

// Types du canal `subagents` de l'hôte (`packages/shared/src/subagents-types.ts`, ZCode 3.15.1). Le canal n'a aucun
// événement : il ne faut jamais l'écouter. Le décodage est tolérant (champ inconnu ignoré, valeur d'énumération
// inconnue gardée telle quelle, seuls `id`, `name` et `path` sont indispensables). Les chaînes sont gardées comme
// l'hôte les renvoie : il échappe guillemets et barres obliques inverses de `description` à l'écriture sans les
// restituer à la lecture, et c'est au formulaire d'en tenir compte.

/// Portée d'un sous-agent dans la liste de l'hôte.
public struct AgentScope: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let builtIn = AgentScope(rawValue: "built-in")
    public static let workspace = AgentScope(rawValue: "workspace")
    public static let user = AgentScope(rawValue: "user")
}

/// Origine d'un sous-agent : intégré à ZCode, fichier de l'utilisateur ou fourni par un plugin.
public struct AgentSource: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let builtIn = AgentSource(rawValue: "built-in")
    public static let user = AgentSource(rawValue: "user")
    public static let plugin = AgentSource(rawValue: "plugin")
}

/// Couleur d'un sous-agent. Les huit valeurs viennent de ZCode Web (l'hôte n'en publie pas la liste) ; une autre est
/// gardée telle quelle.
public struct AgentColor: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let red = AgentColor(rawValue: "red")
    public static let blue = AgentColor(rawValue: "blue")
    public static let green = AgentColor(rawValue: "green")
    public static let yellow = AgentColor(rawValue: "yellow")
    public static let purple = AgentColor(rawValue: "purple")
    public static let orange = AgentColor(rawValue: "orange")
    public static let pink = AgentColor(rawValue: "pink")
    public static let cyan = AgentColor(rawValue: "cyan")

    /// Ordre de présentation de l'interface web.
    public static let webOrder: [AgentColor] = [.yellow, .red, .orange, .green, .cyan, .blue, .purple, .pink]
}

/// Mode d'autorisation d'un sous-agent (liste copiée de ZCode Web). Le runtime l'ignore dans un fichier de projet.
public struct AgentPermissionMode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let acceptEdits = AgentPermissionMode(rawValue: "acceptEdits")
    public static let auto = AgentPermissionMode(rawValue: "auto")
    public static let bypassPermissions = AgentPermissionMode(rawValue: "bypassPermissions")
    public static let defaultMode = AgentPermissionMode(rawValue: "default")
    public static let dontAsk = AgentPermissionMode(rawValue: "dontAsk")
    public static let plan = AgentPermissionMode(rawValue: "plan")
}

/// Anomalie signalée par l'hôte en lisant les fichiers d'agents (ex. nom ambigu entre deux plugins).
public struct AgentDiagnostic: Equatable, Sendable {
    public let code: String
    public let message: String
    public let path: String?

    public init(code: String, message: String, path: String?) {
        self.code = code
        self.message = message
        self.path = path
    }

    init?(json: JSONValue) {
        let code = json["code"]?.stringValue
        let message = json["message"]?.stringValue
        guard code != nil || message != nil else { return nil }
        self.init(code: code ?? "", message: message ?? "", path: json["path"]?.stringValue)
    }

    static func list(_ json: JSONValue?) -> [AgentDiagnostic] {
        (json?.arrayValue ?? []).compactMap(AgentDiagnostic.init(json:))
    }
}

private func stringList(_ json: JSONValue?) -> [String]? {
    json?.arrayValue.map { $0.compactMap(\.stringValue) }
}

private func decodeModelSelection(_ json: JSONValue?) -> ModelSelection? {
    guard let json, json.objectValue != nil else { return nil }
    return try? V4JSON.decode(ModelSelection.self, from: json)
}

/// Sous-agent tel que la liste de l'hôte le décrit (`AgentSummary`).
public struct AgentSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var systemPrompt: String
    /// Chemin du fichier sur l'hôte ; `built-in:<nom>` pour un intégré. À renvoyer tel quel pour renommer ou supprimer.
    public var path: String

    public var color: AgentColor?
    public var modelSelection: ModelSelection?
    public var defaultModelSelection: ModelSelection?
    public var modelSelectionOverride: ModelSelection?

    public var tools: [String]?
    public var disallowedTools: [String]?
    public var skills: [String]?
    public var injectAgentsMd: Bool?
    public var permissionMode: AgentPermissionMode?
    public var maxTurns: Int?
    public var background: Bool?
    /// Serveurs MCP opaques, renvoyés tels quels à l'enregistrement.
    public var mcpServers: [JSONValue]?

    public var scope: AgentScope
    public var source: AgentSource
    public var enabled: Bool
    public var readOnly: Bool
    public var projectPath: String?
    public var pluginId: String?
    public var pluginName: String?
    public var diagnostics: [AgentDiagnostic]

    /// `nil` sans `id`, `name` ou `path`.
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["id"]?.stringValue, let name = json["name"]?.stringValue,
              let path = json["path"]?.stringValue
        else { return nil }
        self.id = id
        self.name = name
        self.path = path
        description = json["description"]?.stringValue ?? ""
        systemPrompt = json["systemPrompt"]?.stringValue ?? ""
        color = json["color"]?.stringValue.map(AgentColor.init(rawValue:))
        modelSelection = decodeModelSelection(json["modelSelection"])
        defaultModelSelection = decodeModelSelection(json["defaultModelSelection"])
        modelSelectionOverride = decodeModelSelection(json["modelSelectionOverride"])
        tools = stringList(json["tools"])
        disallowedTools = stringList(json["disallowedTools"])
        skills = stringList(json["skills"])
        injectAgentsMd = json["injectAgentsMd"]?.boolValue
        permissionMode = json["permissionMode"]?.stringValue.map(AgentPermissionMode.init(rawValue:))
        maxTurns = V4JSON.integer(json["maxTurns"])
        background = json["background"]?.boolValue
        mcpServers = json["mcpServers"]?.arrayValue
        scope = AgentScope(rawValue: json["scope"]?.stringValue ?? "")
        source = AgentSource(rawValue: json["source"]?.stringValue ?? "")
        enabled = json["enabled"]?.boolValue ?? true
        readOnly = json["readOnly"]?.boolValue ?? false
        projectPath = json["projectPath"]?.stringValue
        pluginId = json["pluginId"]?.stringValue
        pluginName = json["pluginName"]?.stringValue
        diagnostics = AgentDiagnostic.list(json["diagnostics"])
    }

    /// Modifiable ou supprimable : un fichier de l'utilisateur (portée utilisateur ou projet), jamais en lecture seule.
    /// L'hôte ne l'impose pas, c'est le client qui le garantit.
    public var isEditable: Bool {
        source == .user && (scope == .user || scope == .workspace) && !readOnly
    }

    /// L'hôte ne sait activer ou désactiver que `user:user:<nom>`.
    public var canToggleEnabled: Bool { isEditable && scope == .user }
}

/// Réponse de `subagents.list`.
public struct AgentsListResult: Equatable, Sendable {
    /// Tout ce que voit le runtime (intégrés, utilisateur, projet, plugins sous leur alias).
    public let agents: [AgentSummary]
    public let userAgents: [AgentSummary]
    /// Agents de plugins sous leur identifiant canonique (`plugin:<plugin>@<marketplace>:<nom>`) : à afficher plutôt
    /// que les alias de `agents`.
    public let pluginAgents: [AgentSummary]
    public let userScopeAvailable: Bool
    public let userScopeReason: String?
    public let diagnostics: [AgentDiagnostic]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("subagents.list") }
        func list(_ key: String) -> [AgentSummary] {
            (json[key]?.arrayValue ?? []).compactMap(AgentSummary.init(json:))
        }
        agents = list("agents")
        userAgents = list("userAgents")
        pluginAgents = list("pluginAgents")
        userScopeAvailable = json["capability"]?["userScopeAvailable"]?.boolValue ?? true
        userScopeReason = json["capability"]?["userScopeReason"]?.stringValue
        diagnostics = AgentDiagnostic.list(json["diagnostics"])
    }
}

/// Définition envoyée à `createAgent` / `updateAgent` (`SubAgentConfig`). Seuls nom, description et instructions sont
/// obligatoires ; une clé sans valeur est omise du JSON.
public struct SubAgentConfig: Equatable, Sendable {
    public var name: String
    public var description: String
    public var systemPrompt: String
    public var color: AgentColor?
    public var modelSelection: ModelSelection?
    public var tools: [String]?
    public var disallowedTools: [String]?
    public var skills: [String]?
    public var injectAgentsMd: Bool?
    public var permissionMode: AgentPermissionMode?
    public var maxTurns: Int?
    public var background: Bool?
    public var mcpServers: [JSONValue]?

    public init(name: String, description: String, systemPrompt: String) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
    }

    /// Copie fidèle des champs éditables d'un agent lu : l'hôte réécrit tout le fichier, un champ oublié serait perdu.
    public init(_ agent: AgentSummary) {
        self.init(name: agent.name, description: agent.description, systemPrompt: agent.systemPrompt)
        color = agent.color
        modelSelection = agent.modelSelection
        tools = agent.tools
        disallowedTools = agent.disallowedTools
        skills = agent.skills
        injectAgentsMd = agent.injectAgentsMd
        permissionMode = agent.permissionMode
        maxTurns = agent.maxTurns
        background = agent.background
        mcpServers = agent.mcpServers
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "systemPrompt": .string(systemPrompt),
        ]
        if let color { object["color"] = .string(color.rawValue) }
        if let modelSelection, let encoded = try? V4JSON.encode(modelSelection) { object["modelSelection"] = encoded }
        if let tools { object["tools"] = .array(tools.map(JSONValue.string)) }
        if let disallowedTools { object["disallowedTools"] = .array(disallowedTools.map(JSONValue.string)) }
        if let skills { object["skills"] = .array(skills.map(JSONValue.string)) }
        if let injectAgentsMd { object["injectAgentsMd"] = .bool(injectAgentsMd) }
        if let permissionMode { object["permissionMode"] = .string(permissionMode.rawValue) }
        if let maxTurns { object["maxTurns"] = .number(Double(maxTurns)) }
        if let background { object["background"] = .bool(background) }
        if let mcpServers { object["mcpServers"] = .array(mcpServers) }
        return .object(object)
    }
}
