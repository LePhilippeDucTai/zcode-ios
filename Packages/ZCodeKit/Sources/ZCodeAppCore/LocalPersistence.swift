import Foundation
import Synchronization

/// Données d'un état local de l'app (vu, épingles…) : une clé UserDefaults versionnée par état.
public protocol LocalPersistence: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

public struct UserDefaultsLocalPersistence: LocalPersistence {
    public let key: String
    private let suiteName: String?

    public init(key: String, suiteName: String? = nil) {
        self.key = key
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> Data? { defaults.data(forKey: key) }
    public func save(_ data: Data) { defaults.set(data, forKey: key) }
}

public final class InMemoryLocalPersistence: LocalPersistence {
    private let data = Mutex<Data?>(nil)

    public init() {}

    public func load() -> Data? { data.withLock { $0 } }
    public func save(_ data: Data) { self.data.withLock { $0 = data } }
}

/// Une session d'un projet d'un hôte : clé des états tenus sur cet iPhone.
public struct SessionKey: Hashable, Sendable {
    public let hostId: UUID
    public let workspace: String
    public let sessionId: String

    public init(hostId: UUID, workspace: String, sessionId: String) {
        self.hostId = hostId
        self.workspace = workspace
        self.sessionId = sessionId
    }

    /// Préfixe des clés d'un projet ; séparateur U+001F, absent des chemins et des identifiants de session.
    public static func projectPrefix(hostId: UUID, workspace: String) -> String {
        "\(hostId.uuidString)\u{1F}\(workspace)\u{1F}"
    }

    /// Clé de stockage (dictionnaire JSON).
    public var storageKey: String { Self.projectPrefix(hostId: hostId, workspace: workspace) + sessionId }

    /// Clés d'un projet dont la session n'est plus dans `keeping` (les autres projets ne sont pas touchés).
    public static func staleKeys(in keys: some Sequence<String>, hostId: UUID, workspace: String,
                                 keeping sessionIds: Set<String>) -> [String] {
        let prefix = projectPrefix(hostId: hostId, workspace: workspace)
        return keys.filter { $0.hasPrefix(prefix) && !sessionIds.contains(String($0.dropFirst(prefix.count))) }
    }
}
