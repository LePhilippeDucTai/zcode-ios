import Foundation
import ZCodeWire

/// Type d'un argument de workflow enregistré (`zcode-agent.listSavedWorkflows`).
public struct WorkflowArgType: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let string = WorkflowArgType(rawValue: "string")
    public static let number = WorkflowArgType(rawValue: "number")
    public static let boolean = WorkflowArgType(rawValue: "boolean")
    public static let json = WorkflowArgType(rawValue: "json")
}

public struct WorkflowArgSpec: Equatable, Sendable {
    public let name: String
    public let type: WorkflowArgType
    public let description: String?
    public let required: Bool
    public let defaultValue: JSONValue?

    public init(name: String, type: WorkflowArgType, description: String? = nil, required: Bool = false,
                defaultValue: JSONValue? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
    }
}

public struct SavedWorkflowScope: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let project = SavedWorkflowScope(rawValue: "project")
    public static let global = SavedWorkflowScope(rawValue: "global")
}

/// Workflow enregistré (`*.dwf.ts`) que l'hôte sait lancer.
public struct SavedWorkflow: Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let whenToUse: String?
    public let scope: SavedWorkflowScope
    public let path: String
    /// Requis d'abord, puis ordre alphabétique (`JSONValue.object` n'a pas d'ordre).
    public let args: [WorkflowArgSpec]

    public var id: String { "\(scope.rawValue)/\(name)" }

    public init(name: String, description: String, whenToUse: String? = nil, scope: SavedWorkflowScope,
                path: String, args: [WorkflowArgSpec] = []) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.scope = scope
        self.path = path
        self.args = args
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, let description = json["description"]?.stringValue,
              let path = json["path"]?.stringValue else { return nil }
        self.init(
            name: name, description: description, whenToUse: json["whenToUse"]?.stringValue,
            scope: SavedWorkflowScope(rawValue: json["scope"]?.stringValue ?? ""), path: path,
            args: Self.args(json["args"])
        )
    }

    private static func args(_ json: JSONValue?) -> [WorkflowArgSpec] {
        (json?.objectValue ?? [:]).map { name, spec in
            WorkflowArgSpec(
                name: name, type: WorkflowArgType(rawValue: spec["type"]?.stringValue ?? ""),
                description: spec["description"]?.stringValue, required: spec["required"]?.boolValue ?? false,
                defaultValue: spec["default"]
            )
        }
        .sorted { ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name) }
    }
}

/// Fichier de workflow que l'hôte refuse de charger, avec sa raison.
public struct InvalidSavedWorkflow: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct SavedWorkflowList: Equatable, Sendable {
    public let workflows: [SavedWorkflow]
    public let invalid: [InvalidSavedWorkflow]
    public let dir: String?

    /// Lève seulement si la valeur n'est pas un objet ; un élément illisible est ignoré.
    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("savedWorkflows") }
        workflows = (json["workflows"]?.arrayValue ?? []).compactMap(SavedWorkflow.init(json:))
        invalid = (json["invalid"]?.arrayValue ?? []).compactMap { item in
            item["path"]?.stringValue.map { InvalidSavedWorkflow(path: $0, reason: item["reason"]?.stringValue ?? "") }
        }
        dir = json["dir"]?.stringValue
    }
}
