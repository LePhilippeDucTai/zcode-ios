import Foundation
import Synchronization

/// Stockage du `clientId` (pas un secret : il sert à reconnaître les commandes de ce client).
public protocol ClientIDStorage: Sendable {
    func load() -> String?
    func save(_ clientId: String)
}

public final class InMemoryClientIDStorage: ClientIDStorage {
    private let value = Mutex<String?>(nil)

    public init() {}

    public func load() -> String? { value.withLock { $0 } }
    public func save(_ clientId: String) { value.withLock { $0 = clientId } }
}

/// `UserDefaults` (app iOS). La même clé que le client web de ZCode.
public struct UserDefaultsClientIDStorage: ClientIDStorage {
    public static let key = "zcode-v4-client-id:v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> String? { defaults.string(forKey: Self.key) }
    public func save(_ clientId: String) { defaults.set(clientId, forKey: Self.key) }
}

public enum ClientIdentity {
    /// `clientId` persistant (`client-<uuidv7>`), créé au premier appel.
    public static func clientId(storage: some ClientIDStorage) -> String {
        if let existing = storage.load(), !existing.isEmpty {
            return existing
        }
        let clientId = "client-" + UUIDv7.make()
        storage.save(clientId)
        return clientId
    }
}
