import Foundation
import Security
import Synchronization

/// Rangement des tokens d'hôte. Un token = accès shell à l'hôte.
public protocol TokenStore: Sendable {
    func token(for hostId: UUID) -> String?
    func setToken(_ token: String, for hostId: UUID) throws
    func removeToken(for hostId: UUID)
}

public final class InMemoryTokenStore: TokenStore {
    private let tokens = Mutex<[UUID: String]>([:])

    public init() {}

    public func token(for hostId: UUID) -> String? { tokens.withLock { $0[hostId] } }
    public func setToken(_ token: String, for hostId: UUID) throws { tokens.withLock { $0[hostId] = token } }
    public func removeToken(for hostId: UUID) { _ = tokens.withLock { $0.removeValue(forKey: hostId) } }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// Trousseau de l'appareil : élément « mot de passe générique » par hôte, lisible après le premier
/// déverrouillage, jamais synchronisé ni sauvegardé hors de cet appareil.
public struct KeychainTokenStore: TokenStore {
    public static let service = "zcode-ios.host-token"

    public init() {}

    private func query(_ hostId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: hostId.uuidString,
        ]
    }

    public func token(for hostId: UUID) -> String? {
        var query = query(hostId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, for hostId: UUID) throws {
        SecItemDelete(query(hostId) as CFDictionary)
        var item = query(hostId)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func removeToken(for hostId: UUID) {
        SecItemDelete(query(hostId) as CFDictionary)
    }
}
