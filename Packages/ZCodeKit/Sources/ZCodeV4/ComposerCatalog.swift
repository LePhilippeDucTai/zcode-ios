import Foundation
import ZCodeWire

// Catalogues du composeur (lot 13C), lus comme ZCode Web 3.15.1 : commandes du projet (`readWorkspacePresentation`),
// skills référençables (`getSkillReferenceCatalog`) et droit aux workflows dynamiques (`getDynamicWorkflowClientConfig`).
// Décodage tolérant : champ inconnu ignoré, valeur d'énumération inconnue gardée, entrée sans nom écartée.

/// Commande du panneau « / » (`zcodeSlashCommandSchema`).
public struct SlashCommandInfo: Equatable, Sendable {
    /// Tel que l'hôte le donne (il peut commencer par « / », que l'app retire à l'affichage).
    public let name: String
    public let description: String
    /// Usage complet (« /goal [objectif] ») quand l'hôte en donne un.
    public let inputHint: String?
    /// `builtin` ou `custom` ; absent sur un hôte plus ancien.
    public let source: String?

    public init(name: String, description: String = "", inputHint: String? = nil, source: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
        self.source = source
    }

    /// `nil` sans nom.
    public init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.init(name: name, description: json["description"]?.stringValue ?? "",
                  inputHint: json["inputHint"]?.stringValue, source: json["source"]?.stringValue)
    }
}

/// Réponse de `readWorkspacePresentation` : mode du projet et commandes du panneau.
public struct WorkspacePresentation: Equatable, Sendable {
    public let mode: String?
    public let slashCommands: [SlashCommandInfo]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("readWorkspacePresentation") }
        mode = json["mode"]?.stringValue
        slashCommands = (json["slashCommands"]?.arrayValue ?? []).compactMap(SlashCommandInfo.init(json:))
    }
}

/// Portée d'une skill du catalogue.
public struct SkillScope: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let workspace = SkillScope(rawValue: "workspace")
    public static let user = SkillScope(rawValue: "user")
    public static let plugin = SkillScope(rawValue: "plugin")
}

/// Skill référençable depuis le composeur (`zcodeSkillReferenceCatalogEntrySchema`).
public struct SkillReference: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    /// Chemin sur l'hôte, tel quel : repris dans le lien envoyé (`[$nom](chemin)`). Absent : « $nom » seul.
    public let path: String?
    public let scope: SkillScope
    /// Toujours vrai en 3.15.1 (le catalogue ne liste que les skills activées) ; absent = vrai.
    public let enabled: Bool
    public let pluginName: String?

    public init(id: String, name: String, description: String = "", path: String? = nil, scope: SkillScope,
                enabled: Bool = true, pluginName: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.scope = scope
        self.enabled = enabled
        self.pluginName = pluginName
    }

    /// `nil` sans `id` ou `name` ; un chemin absent ou vide est gardé comme absent.
    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let path = json["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        self.init(id: id, name: name, description: json["description"]?.stringValue ?? "", path: path,
                  scope: SkillScope(rawValue: json["scope"]?.stringValue ?? ""),
                  enabled: json["enabled"]?.boolValue ?? true, pluginName: json["pluginName"]?.stringValue)
    }
}

/// Réponse de `getSkillReferenceCatalog` : `authority` = `session` (catalogue figé de la session) ou `workspace`.
public struct SkillReferenceCatalog: Equatable, Sendable {
    public let authority: String?
    public let skills: [SkillReference]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("getSkillReferenceCatalog") }
        authority = json["authority"]?.stringValue
        skills = (json["skills"]?.arrayValue ?? []).compactMap(SkillReference.init(json:))
    }
}

/// Droit aux workflows dynamiques (`DynamicWorkflowClientConfig`, canal `coding-plan-subscription`). L'hôte en est seul
/// juge : un `enabled` absent ou illisible vaut faux, comme l'hôte qui ferme dans le doute.
public struct DynamicWorkflowConfig: Equatable, Sendable {
    /// Mode effectif : `disabled`, `onDemand`, `alwaysOn`, ou une valeur future gardée telle quelle.
    public let mode: String
    public let enabled: Bool
    public let offeredMode: String?
    public let source: String?
    public let userMode: String?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("getDynamicWorkflowClientConfig") }
        mode = json["mode"]?.stringValue ?? "disabled"
        enabled = json["enabled"]?.boolValue == true
        offeredMode = json["offeredMode"]?.stringValue
        source = json["source"]?.stringValue
        userMode = json["userMode"]?.stringValue
    }
}
