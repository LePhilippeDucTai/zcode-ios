import Foundation
import ZCodeWire

/// Accès par compte d'un fournisseur (`ZCodeProviderAccountAccess` de ZCode : `config.access` de type `zhipu-account`,
/// sans secret). C'est ce que l'hôte exige en retour pour lire les quotas du Coding Plan (`usage-stats`). Un accès par
/// clé d'API (`api-key`) porte la clé en clair et n'est jamais décodé.
public struct ProviderAccountAccess: Equatable, Sendable {
    /// `zai` ou `bigmodel`.
    public let accountType: String
    /// `individual-coding-plan`, `team-coding-plan`, `start-plan`, `off-peak` ou `highspeed`.
    public let mode: String
    public let entitled: Bool

    public init(accountType: String, mode: String, entitled: Bool) {
        self.accountType = accountType
        self.mode = mode
        self.entitled = entitled
    }

    /// `nil` sauf pour un `zhipu-account` complet : l'hôte valide strictement ces quatre champs à la réception.
    public init?(json: JSONValue?) {
        guard let json, json["type"]?.stringValue == "zhipu-account",
              let accountType = json["accountType"]?.stringValue, !accountType.isEmpty,
              let mode = json["mode"]?.stringValue, !mode.isEmpty,
              let entitled = json["entitled"]?.boolValue else { return nil }
        self.init(accountType: accountType, mode: mode, entitled: entitled)
    }

    /// Forme renvoyée à l'hôte (`accountAccess` de `usage-stats.getEntitlementSnapshot`).
    public var json: JSONValue {
        .object([
            "type": .string("zhipu-account"), "accountType": .string(accountType), "mode": .string(mode),
            "entitled": .bool(entitled),
        ])
    }

    /// Un compte dont les quotas se lisent : droits actifs, hors accès `off-peak` (file d'attente des heures creuses,
    /// sans quota propre, écarté aussi par l'interface web).
    public var canReadUsage: Bool { entitled && mode != "off-peak" }
}

/// Vue du canal `model-selection` (`ModelSelectionView` de ZCode) : fournisseurs, modèles et niveaux d'effort que
/// l'hôte propose. Lue champ par champ : `providers[].config.access` peut porter une clé d'API en clair et n'est
/// jamais conservé (seul un accès par compte, sans secret, l'est : `Provider.accountAccess`).
public struct ModelSelectionView: Equatable, Sendable {
    public struct Model: Equatable, Sendable, Identifiable {
        public let modelId: String
        public let enabled: Bool
        /// `optionSpecs.reasoningLevel.values`, du plus faible au plus fort (`["none"]` pour Mistral).
        public let reasoningLevels: [String]
        public let contextWindow: Int?
        public var id: String { modelId }
    }

    public struct Provider: Equatable, Sendable, Identifiable {
        public let providerId: String
        /// `providerName`, sinon l'identifiant.
        public let name: String
        public let models: [Model]
        /// Accès par compte Z.ai / BigModel (`config.access` de type `zhipu-account`) ; `nil` pour un fournisseur à clé
        /// d'API ou un accès incomplet.
        public let accountAccess: ProviderAccountAccess?
        public var id: String { providerId }
        /// Modèles proposables (les modèles désactivés dans ZCode sont masqués).
        public var visibleModels: [Model] { models.filter(\.enabled) }
    }

    /// Croissante tant que le serveur tourne (repart de zéro s'il redémarre).
    public let revision: Int
    public let providers: [Provider]
    /// Choix par défaut de l'hôte, toujours muni d'un niveau d'effort.
    public let preferredSelection: ModelSelection?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let object = json.objectValue else { throw .invalid("model-selection") }
        revision = V4JSON.integer(object["revision"]) ?? 0
        providers = (object["providers"]?.arrayValue ?? []).compactMap(Self.provider)
        preferredSelection = object["preferredSelection"].flatMap { try? V4JSON.decode(ModelSelection.self, from: $0) }
    }

    public func provider(id: String) -> Provider? {
        providers.first { $0.providerId == id }
    }

    public func model(providerId: String, modelId: String) -> Model? {
        provider(id: providerId)?.models.first { $0.modelId == modelId }
    }

    private static func provider(_ json: JSONValue) -> Provider? {
        guard let id = json["providerId"]?.stringValue, !id.isEmpty else { return nil }
        let name = json["providerName"]?.stringValue ?? ""
        return Provider(providerId: id, name: name.isEmpty ? id : name,
                        models: (json["models"]?.arrayValue ?? []).compactMap(Self.model),
                        accountAccess: ProviderAccountAccess(json: json["config"]?["access"]))
    }

    private static func model(_ json: JSONValue) -> Model? {
        guard let id = json["modelId"]?.stringValue, !id.isEmpty else { return nil }
        let config = json["config"]
        let levels = config?["optionSpecs"]?["reasoningLevel"]?["values"]?.arrayValue ?? []
        return Model(modelId: id, enabled: config?["enabled"]?.boolValue ?? true,
                     reasoningLevels: levels.compactMap(\.stringValue),
                     contextWindow: V4JSON.integer(config?["properties"]?["contextWindow"]))
    }
}
