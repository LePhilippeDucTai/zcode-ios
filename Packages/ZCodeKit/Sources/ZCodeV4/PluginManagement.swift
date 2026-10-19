import Foundation
import ZCodeWire

// Types du canal `plugin-management` de l'hôte (`packages/shared/src/zcode-protocol/index.ts`, ZCode 3.15.1). Le canal
// relaie les appels vers le processus CLI de l'hôte, qui gère marketplaces, installations et configuration : aucun
// événement n'est utilisé (`onDynamicPluginOperationProgress` n'émet que pour les références suggérées) et les échecs
// d'une opération arrivent dans les `diagnostics` d'une réponse de succès. Le décodage est tolérant : un champ inconnu
// est ignoré, une valeur d'énumération inconnue est gardée telle quelle, une entrée de liste sans `id` est écartée.
// Deux données ne sont jamais décodées : les `headers` d'une source `url` (secrets) et la valeur d'une option
// `sensitive` (l'hôte ne la renvoie pas, et le décodage la retire même s'il l'envoyait).

/// Type de composant d'un plugin ; une valeur inconnue est gardée telle quelle.
public struct PluginComponentKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let agent = PluginComponentKind(rawValue: "agent")
    public static let command = PluginComponentKind(rawValue: "command")
    public static let skill = PluginComponentKind(rawValue: "skill")
    public static let hook = PluginComponentKind(rawValue: "hook")
    public static let mcp = PluginComponentKind(rawValue: "mcp")
    public static let lsp = PluginComponentKind(rawValue: "lsp")
}

/// État de mise à jour d'un plugin installé, tel que l'hôte le compare à son catalogue en cache.
public struct PluginUpdateStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let none = PluginUpdateStatus(rawValue: "none")
    public static let updateAvailable = PluginUpdateStatus(rawValue: "update-available")
    public static let versionChanged = PluginUpdateStatus(rawValue: "version-changed")
}

/// Anomalie ou échec signalé par l'hôte. Une réponse de succès qui porte un diagnostic `severity: "error"` est un échec.
public struct PluginDiagnostic: Equatable, Sendable {
    public let code: String
    public let message: String
    public let severity: String?
    public let pluginId: String?

    public init(code: String, message: String, severity: String? = nil, pluginId: String? = nil) {
        self.code = code
        self.message = message
        self.severity = severity
        self.pluginId = pluginId
    }

    public init?(json: JSONValue) {
        let code = json["code"]?.stringValue
        let message = json["message"]?.stringValue
        guard code != nil || message != nil else { return nil }
        self.init(code: code ?? "", message: message ?? "", severity: json["severity"]?.stringValue,
                  pluginId: json["pluginId"]?.stringValue)
    }

    public var isError: Bool { severity == "error" }

    /// Liste de diagnostics d'une réponse ; absente ou illisible = vide.
    public static func list(_ json: JSONValue?) -> [PluginDiagnostic] {
        (json?.arrayValue ?? []).compactMap(PluginDiagnostic.init(json:))
    }
}

private func compactStrings(_ json: JSONValue?) -> [String] {
    json?.arrayValue?.compactMap(\.stringValue) ?? []
}

private func stringMap(_ json: JSONValue?) -> [String: String] {
    (json?.objectValue ?? [:]).compactMapValues(\.stringValue)
}

private func componentKinds(_ json: JSONValue?) -> [PluginComponentKind] {
    compactStrings(json).map(PluginComponentKind.init(rawValue:))
}

/// Valeur d'option de plugin : chaîne, nombre ou booléen (le reste est ignoré).
private func optionValue(_ json: JSONValue?) -> JSONValue? {
    switch json {
    case .string?, .number?, .bool?: json
    default: nil
    }
}

/// Composants d'un même type (compétences, commandes…) d'un plugin, avec leurs noms et descriptions.
public struct PluginComponentGroup: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    public let kind: PluginComponentKind
    public let items: [Item]

    public init(kind: PluginComponentKind, items: [Item]) {
        self.kind = kind
        self.items = items
    }

    /// `nil` sans `kind`.
    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue else { return nil }
        self.kind = PluginComponentKind(rawValue: kind)
        items = (json["items"]?.arrayValue ?? []).compactMap { item in
            item["name"]?.stringValue.map { Item(name: $0, description: item["description"]?.stringValue) }
        }
    }

    static func list(_ json: JSONValue?) -> [PluginComponentGroup] {
        (json?.arrayValue ?? []).compactMap(PluginComponentGroup.init(json:))
    }
}

/// Crochet (hook) déclaré par un plugin ; sa forme vient des sources de l'hôte (aucun hook sur les hôtes enregistrés).
public struct PluginHookDetail: Equatable, Sendable {
    public let event: String
    public let command: String
    public let matcher: String?
    public let runnable: Bool

    public init(event: String, command: String, matcher: String? = nil, runnable: Bool = false) {
        self.event = event
        self.command = command
        self.matcher = matcher
        self.runnable = runnable
    }

    init?(json: JSONValue) {
        guard let event = json["event"]?.stringValue, let command = json["command"]?.stringValue else { return nil }
        self.init(event: event, command: command, matcher: json["matcher"]?.stringValue,
                  runnable: json["runnable"]?.boolValue ?? false)
    }
}

/// Fiche de présentation d'un plugin dans le catalogue (`listing`). Les autres clés (icône, image, exemples…) sont
/// ignorées : l'iPhone ne parle qu'à l'hôte et ne charge aucune image du CDN.
public struct PluginListing: Equatable, Sendable {
    public var displayName: String?
    public var displayNameI18n: [String: String]
    public var descriptionI18n: [String: String]
    public var category: String?
    public var author: String?
    public var homepage: String?
    public var requiresPaidPlan: Bool

    public init(displayName: String? = nil, displayNameI18n: [String: String] = [:],
                descriptionI18n: [String: String] = [:], category: String? = nil, author: String? = nil,
                homepage: String? = nil, requiresPaidPlan: Bool = false) {
        self.displayName = displayName
        self.displayNameI18n = displayNameI18n
        self.descriptionI18n = descriptionI18n
        self.category = category
        self.author = author
        self.homepage = homepage
        self.requiresPaidPlan = requiresPaidPlan
    }

    init?(json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        self.init(
            displayName: json["displayName"]?.stringValue,
            displayNameI18n: stringMap(json["displayNameI18n"]),
            descriptionI18n: stringMap(json["descriptionI18n"]),
            category: json["category"]?.stringValue,
            author: json["author"]?.stringValue,
            homepage: json["homepage"]?.stringValue,
            requiresPaidPlan: json["requiresPaidPlan"]?.boolValue ?? false
        )
    }
}

/// Source de plugins (marketplace) : officielle ou personnelle.
public struct MarketplaceSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var lastUpdated: Date?
    /// Nombre annoncé par l'hôte : il peut différer du nombre d'entrées du catalogue.
    public var pluginCount: Int
    public var isOfficial: Bool
    /// Message du dernier échec d'actualisation.
    public var refreshFailure: String?
    /// Genre de source (`source.source` : `github`, `url`, `directory`…).
    public var sourceKind: String?
    /// Dépôt, adresse ou chemin de la source (`repo`, `url` ou `path`). Les `headers` ne sont jamais lus.
    public var sourceLabel: String?

    public init(id: String, name: String, description: String? = nil, lastUpdated: Date? = nil, pluginCount: Int = 0,
                isOfficial: Bool = false, refreshFailure: String? = nil, sourceKind: String? = nil,
                sourceLabel: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.lastUpdated = lastUpdated
        self.pluginCount = pluginCount
        self.isOfficial = isOfficial
        self.refreshFailure = refreshFailure
        self.sourceKind = sourceKind
        self.sourceLabel = sourceLabel
    }

    /// `nil` sans `id` ni `name`.
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["id"]?.stringValue, let name = json["name"]?.stringValue else {
            return nil
        }
        let source = json["source"]
        self.init(
            id: id, name: name,
            description: json["description"]?.stringValue,
            lastUpdated: UsageDates.iso8601(json["lastUpdated"]),
            pluginCount: V4JSON.integer(json["pluginCount"]) ?? 0,
            isOfficial: json["isOfficial"]?.boolValue ?? false,
            refreshFailure: json["refreshFailure"]?["message"]?.stringValue,
            sourceKind: source?["source"]?.stringValue,
            sourceLabel: source?["repo"]?.stringValue ?? source?["url"]?.stringValue ?? source?["path"]?.stringValue
        )
    }

    static func list(_ json: JSONValue?) -> [MarketplaceSummary] {
        (json?.arrayValue ?? []).compactMap(MarketplaceSummary.init(json:))
    }
}

/// Plugin proposé par un catalogue.
public struct AvailablePlugin: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var marketplace: String
    public var description: String?
    public var version: String?
    public var installed: Bool
    public var componentTypes: [PluginComponentKind]
    public var listing: PluginListing?

    public init(id: String, name: String, marketplace: String, description: String? = nil, version: String? = nil,
                installed: Bool = false, componentTypes: [PluginComponentKind] = [], listing: PluginListing? = nil) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.description = description
        self.version = version
        self.installed = installed
        self.componentTypes = componentTypes
        self.listing = listing
    }

    /// `nil` sans `id`. Sans `name` ou `marketplace`, ils se déduisent de l'id canonique `<nom>@<marketplace>`.
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["id"]?.stringValue else { return nil }
        let parts = PluginIdentity(id)
        self.init(
            id: id, name: json["name"]?.stringValue ?? parts.name,
            marketplace: json["marketplace"]?.stringValue ?? parts.marketplace,
            description: json["description"]?.stringValue,
            version: json["version"]?.stringValue,
            installed: json["installed"]?.boolValue ?? false,
            componentTypes: componentKinds(json["componentTypes"]),
            listing: PluginListing(json: json["listing"])
        )
    }

    static func list(_ json: JSONValue?) -> [AvailablePlugin] {
        (json?.arrayValue ?? []).compactMap(AvailablePlugin.init(json:))
    }
}

/// Plugin installé, tel que le résume l'aperçu ou le résultat d'une installation (qui ne porte ni `componentTypes`, ni
/// `listing`, ni `updateStatus`).
public struct InstalledPlugin: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var marketplace: String
    public var description: String?
    public var version: String?
    public var latestVersion: String?
    public var enabled: Bool
    public var scope: String
    public var installedAt: Date?
    public var componentTypes: [PluginComponentKind]
    public var updateStatus: PluginUpdateStatus
    public var listing: PluginListing?

    public init(id: String, name: String, marketplace: String, description: String? = nil, version: String? = nil,
                latestVersion: String? = nil, enabled: Bool = false, scope: String = "user", installedAt: Date? = nil,
                componentTypes: [PluginComponentKind] = [], updateStatus: PluginUpdateStatus = .none,
                listing: PluginListing? = nil) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.description = description
        self.version = version
        self.latestVersion = latestVersion
        self.enabled = enabled
        self.scope = scope
        self.installedAt = installedAt
        self.componentTypes = componentTypes
        self.updateStatus = updateStatus
        self.listing = listing
    }

    /// `nil` sans `id`. Sans `name` ou `marketplace`, ils se déduisent de l'id canonique ; sans `scope`, l'installation
    /// est celle de l'utilisateur (l'hôte n'en connaît pas d'autre).
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["id"]?.stringValue else { return nil }
        let parts = PluginIdentity(id)
        self.init(
            id: id, name: json["name"]?.stringValue ?? parts.name,
            marketplace: json["marketplace"]?.stringValue ?? parts.marketplace,
            description: json["description"]?.stringValue,
            version: json["version"]?.stringValue,
            latestVersion: json["latestVersion"]?.stringValue,
            enabled: json["enabled"]?.boolValue ?? false,
            scope: json["scope"]?.stringValue ?? "user",
            installedAt: UsageDates.iso8601(json["installedAt"]),
            componentTypes: componentKinds(json["componentTypes"]),
            updateStatus: json["updateStatus"]?.stringValue.map(PluginUpdateStatus.init(rawValue:)) ?? .none,
            listing: PluginListing(json: json["listing"])
        )
    }

    static func list(_ json: JSONValue?) -> [InstalledPlugin] {
        (json?.arrayValue ?? []).compactMap(InstalledPlugin.init(json:))
    }
}

/// Découpe d'un identifiant canonique `<nom>@<marketplace>`.
private struct PluginIdentity {
    let name: String
    let marketplace: String

    init(_ id: String) {
        if let at = id.lastIndex(of: "@") {
            name = String(id[..<at])
            marketplace = String(id[id.index(after: at)...])
        } else {
            name = id
            marketplace = ""
        }
    }
}

/// Réponse de `getPluginsOverview`.
public struct PluginsOverview: Equatable, Sendable {
    public let marketplaces: [MarketplaceSummary]
    public let availablePlugins: [AvailablePlugin]
    public let installedPlugins: [InstalledPlugin]
    /// Plugins intégrés désinstallés, qu'on peut rétablir.
    public let restorableBuiltins: [AvailablePlugin]
    public let diagnostics: [PluginDiagnostic]
    public let supported: Bool
    public let unsupportedReason: String?

    public init(marketplaces: [MarketplaceSummary] = [], availablePlugins: [AvailablePlugin] = [],
                installedPlugins: [InstalledPlugin] = [], restorableBuiltins: [AvailablePlugin] = [],
                diagnostics: [PluginDiagnostic] = [], supported: Bool = true, unsupportedReason: String? = nil) {
        self.marketplaces = marketplaces
        self.availablePlugins = availablePlugins
        self.installedPlugins = installedPlugins
        self.restorableBuiltins = restorableBuiltins
        self.diagnostics = diagnostics
        self.supported = supported
        self.unsupportedReason = unsupportedReason
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("plugin-management.getPluginsOverview") }
        self.init(
            marketplaces: MarketplaceSummary.list(json["marketplaces"]),
            availablePlugins: AvailablePlugin.list(json["availablePlugins"]),
            installedPlugins: InstalledPlugin.list(json["installedPlugins"]),
            restorableBuiltins: AvailablePlugin.list(json["restorableBuiltins"]),
            diagnostics: PluginDiagnostic.list(json["diagnostics"]),
            supported: json["capability"]?["supported"]?.boolValue ?? true,
            unsupportedReason: json["capability"]?["reason"]?.stringValue
        )
    }
}

/// Option de configuration déclarée par un plugin (`userConfig`).
public struct PluginConfigOption: Equatable, Sendable {
    public var key: String
    /// `string`, `number`, `boolean`, `directory` ou `file` ; un type inconnu ou absent vaut `string`.
    public var type: String
    public var title: String?
    public var description: String?
    public var required: Bool
    /// Option secrète : la valeur n'est jamais renvoyée par l'hôte ni relue.
    public var sensitive: Bool
    public var defaultValue: JSONValue?

    public static let knownTypes: Set<String> = ["string", "number", "boolean", "directory", "file"]

    public init(key: String, type: String = "string", title: String? = nil, description: String? = nil,
                required: Bool = false, sensitive: Bool = false, defaultValue: JSONValue? = nil) {
        self.key = key
        self.type = type
        self.title = title
        self.description = description
        self.required = required
        self.sensitive = sensitive
        self.defaultValue = defaultValue
    }

    init(key: String, json: JSONValue) {
        let type = json["type"]?.stringValue
        self.init(
            key: key, type: type.flatMap { Self.knownTypes.contains($0) ? $0 : nil } ?? "string",
            title: json["title"]?.stringValue, description: json["description"]?.stringValue,
            required: json["required"]?.boolValue ?? false, sensitive: json["sensitive"]?.boolValue ?? false,
            defaultValue: optionValue(json["default"])
        )
    }
}

/// Fiche détaillée d'un plugin installé (`listPlugins`, et `plugin` de `setPluginEnabled`).
public struct PluginInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var marketplace: String
    /// Origine du plugin sur l'hôte (`official`, `cache`…).
    public var source: String
    public var description: String?
    public var version: String?
    public var author: String?
    public var homepage: String?

    public var enabled: Bool
    /// Portée (`user` ou `workspace`) qui fixe l'activation, quand elle est explicite.
    public var enabledSource: String?
    /// Le paquet n'est pas encore matérialisé sur l'hôte (`packageStatus: "missing"`).
    public var packageMissing: Bool

    public var components: [PluginComponentGroup]
    public var hookDetails: [PluginHookDetail]
    public var mcpServerNames: [String]

    /// Options déclarées, triées par clé.
    public var userConfig: [PluginConfigOption]
    /// Valeurs enregistrées, sans les options `sensitive` (retirées au décodage).
    public var configuredOptions: [String: JSONValue]
    /// Portée qui définit chaque option (y compris une option secrète, dont seule la présence est connue).
    public var optionSources: [String: String]

    public init(id: String, name: String, marketplace: String, source: String, description: String? = nil,
                version: String? = nil, author: String? = nil, homepage: String? = nil, enabled: Bool = false,
                enabledSource: String? = nil, packageMissing: Bool = false, components: [PluginComponentGroup] = [],
                hookDetails: [PluginHookDetail] = [], mcpServerNames: [String] = [],
                userConfig: [PluginConfigOption] = [], configuredOptions: [String: JSONValue] = [:],
                optionSources: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.source = source
        self.description = description
        self.version = version
        self.author = author
        self.homepage = homepage
        self.enabled = enabled
        self.enabledSource = enabledSource
        self.packageMissing = packageMissing
        self.components = components
        self.hookDetails = hookDetails
        self.mcpServerNames = mcpServerNames
        self.userConfig = userConfig
        self.configuredOptions = configuredOptions
        self.optionSources = optionSources
    }

    /// `nil` sans `id`.
    public init?(json: JSONValue) {
        guard json.objectValue != nil, let id = json["id"]?.stringValue else { return nil }
        let parts = PluginIdentity(id)
        let options = (json["userConfig"]?.objectValue ?? [:])
            .map { PluginConfigOption(key: $0.key, json: $0.value) }
            .sorted { $0.key < $1.key }
        let secretKeys = Set(options.filter(\.sensitive).map(\.key))
        let configured = (json["configuredOptions"]?.objectValue ?? [:])
            .filter { !secretKeys.contains($0.key) }
            .compactMapValues(optionValue)
        self.init(
            id: id, name: json["name"]?.stringValue ?? parts.name,
            marketplace: json["marketplace"]?.stringValue ?? parts.marketplace,
            source: json["source"]?.stringValue ?? "",
            description: json["description"]?.stringValue, version: json["version"]?.stringValue,
            author: json["author"]?.stringValue, homepage: json["homepage"]?.stringValue,
            enabled: json["enabled"]?.boolValue ?? false,
            enabledSource: json["enabledSource"]?.stringValue,
            packageMissing: json["packageStatus"]?.stringValue == "missing",
            components: PluginComponentGroup.list(json["components"]),
            hookDetails: (json["hookDetails"]?.arrayValue ?? []).compactMap(PluginHookDetail.init(json:)),
            mcpServerNames: compactStrings(json["mcpServerNames"]),
            userConfig: options, configuredOptions: configured, optionSources: stringMap(json["optionSources"])
        )
    }
}

/// Réponse de `listPlugins`.
public struct PluginsList: Equatable, Sendable {
    public let plugins: [PluginInfo]
    public let diagnostics: [PluginDiagnostic]

    public init(plugins: [PluginInfo] = [], diagnostics: [PluginDiagnostic] = []) {
        self.plugins = plugins
        self.diagnostics = diagnostics
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("plugin-management.listPlugins") }
        self.init(
            plugins: (json["plugins"]?.arrayValue ?? []).compactMap(PluginInfo.init(json:)),
            diagnostics: PluginDiagnostic.list(json["diagnostics"])
        )
    }
}

/// Réponse de `describePlugin` : ce que contient un plugin du catalogue, avant de l'installer.
public struct PluginDescription: Equatable, Sendable {
    public let components: [PluginComponentGroup]
    public let diagnostics: [PluginDiagnostic]
    public let author: String?
    public let homepage: String?
    public let version: String?

    public init(components: [PluginComponentGroup] = [], diagnostics: [PluginDiagnostic] = [], author: String? = nil,
                homepage: String? = nil, version: String? = nil) {
        self.components = components
        self.diagnostics = diagnostics
        self.author = author
        self.homepage = homepage
        self.version = version
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("plugin-management.describePlugin") }
        self.init(
            components: PluginComponentGroup.list(json["components"]),
            diagnostics: PluginDiagnostic.list(json["diagnostics"]),
            author: json["metadata"]?["author"]?.stringValue,
            homepage: json["metadata"]?["homepage"]?.stringValue,
            version: json["metadata"]?["version"]?.stringValue
        )
    }

    /// Aucun composant et un diagnostic d'erreur : l'hôte n'a pas pu lire le plugin.
    public var failed: Bool { components.isEmpty && diagnostics.contains(where: \.isError) }
}

/// Réponse de `installPlugin` et `updatePlugin`. Un échec arrive comme un succès portant un diagnostic d'erreur.
public struct PluginInstallResult: Equatable, Sendable {
    public let installedPlugins: [InstalledPlugin]
    public let diagnostics: [PluginDiagnostic]

    public init(installedPlugins: [InstalledPlugin] = [], diagnostics: [PluginDiagnostic] = []) {
        self.installedPlugins = installedPlugins
        self.diagnostics = diagnostics
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("plugin-management.installPlugin") }
        self.init(
            installedPlugins: InstalledPlugin.list(json["installedPlugins"]),
            diagnostics: PluginDiagnostic.list(json["diagnostics"])
        )
    }

    /// Premier diagnostic d'erreur : l'opération a échoué.
    public var failure: PluginDiagnostic? { diagnostics.first(where: \.isError) }
}

/// Réponse de `addPluginMarketplace` (`marketplace`) et `updatePluginMarketplace` (`marketplaces`).
public struct MarketplaceMutationResult: Equatable, Sendable {
    public let marketplace: MarketplaceSummary?
    public let marketplaces: [MarketplaceSummary]
    public let diagnostics: [PluginDiagnostic]

    public init(marketplace: MarketplaceSummary? = nil, marketplaces: [MarketplaceSummary] = [],
                diagnostics: [PluginDiagnostic] = []) {
        self.marketplace = marketplace
        self.marketplaces = marketplaces
        self.diagnostics = diagnostics
    }

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("plugin-management.addPluginMarketplace") }
        self.init(
            marketplace: json["marketplace"].flatMap(MarketplaceSummary.init(json:)),
            marketplaces: MarketplaceSummary.list(json["marketplaces"]),
            diagnostics: PluginDiagnostic.list(json["diagnostics"])
        )
    }

    /// Premier diagnostic d'erreur : l'opération a échoué.
    public var failure: PluginDiagnostic? { diagnostics.first(where: \.isError) }
}
