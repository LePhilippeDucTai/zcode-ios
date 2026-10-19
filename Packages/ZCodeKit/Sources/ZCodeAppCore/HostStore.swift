import Foundation
import Observation
import Synchronization
import ZCodeClient

/// Persistance de la liste des hôtes (sans les tokens).
public protocol HostPersistence: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

public struct UserDefaultsHostPersistence: HostPersistence {
    public static let key = "zcode-hosts:v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> Data? { defaults.data(forKey: Self.key) }
    public func save(_ data: Data) { defaults.set(data, forKey: Self.key) }
}

public final class InMemoryHostPersistence: HostPersistence {
    private let data = Mutex<Data?>(nil)

    public init() {}

    public func load() -> Data? { data.withLock { $0 } }
    public func save(_ data: Data) { self.data.withLock { $0 = data } }
}

/// Hôtes enregistrés sur cet iPhone ; les tokens sont rangés à part (`TokenStore`).
@MainActor
@Observable
public final class HostStore {
    public private(set) var hosts: [Host]
    private let persistence: any HostPersistence
    private let tokens: any TokenStore

    public init(persistence: any HostPersistence, tokens: any TokenStore) {
        self.persistence = persistence
        self.tokens = tokens
        hosts = persistence.load().flatMap { try? JSONDecoder().decode([Host].self, from: $0) } ?? []
    }

    public func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    public func token(for hostId: UUID) -> String? {
        tokens.token(for: hostId)
    }

    /// `nil` si le token manque (Trousseau effacé, restauration sur un autre appareil).
    public func endpoint(for host: Host) -> HostEndpoint? {
        token(for: host.id).map { HostEndpoint(baseURL: host.baseURL, token: $0) }
    }

    @discardableResult
    public func add(name: String, url: String, token: String) throws -> Host {
        let (name, url) = try Self.validated(name: name, url: url)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HostValidationError.emptyToken }
        let host = Host(name: name, baseURL: url)
        try tokens.setToken(token, for: host.id)
        hosts.append(host)
        save()
        return host
    }

    /// `token` vide ou `nil` : token inchangé.
    public func update(_ id: UUID, name: String, url: String, token: String?) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        let (name, url) = try Self.validated(name: name, url: url)
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try tokens.setToken(token, for: id)
        }
        hosts[index].name = name
        hosts[index].baseURL = url
        save()
    }

    public func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        tokens.removeToken(for: id)
        save()
    }

    public func addWorkspace(_ path: String, to id: UUID) throws {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { throw HostValidationError.invalidWorkspace }
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              !hosts[index].manualWorkspaces.contains(path) else { return }
        hosts[index].manualWorkspaces.append(path)
        save()
    }

    public func removeWorkspace(_ path: String, from id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].manualWorkspaces.removeAll { $0 == path }
        save()
    }

    /// Mode des nouvelles sessions de cet hôte (`nil` : défaut de l'hôte).
    public func setDefaultMode(_ mode: String?, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }), hosts[index].defaultMode != mode else { return }
        hosts[index].defaultMode = mode
        save()
    }

    /// Builds DEBUG uniquement (tests UI) : `ZCODE_RESET=1` vide la liste ; `ZCODE_SEED_*` puis `ZCODE_SEED2_*`
    /// (`_NAME`, `_URL`, `_TOKEN`) ajoutent chacun un hôte s'il n'existe pas déjà à cette adresse.
    public func applyDebugSeed(environment: [String: String]) {
        if environment["ZCODE_RESET"] == "1" {
            for host in hosts { remove(host.id) }
        }
        for prefix in ["ZCODE_SEED", "ZCODE_SEED2"] {
            guard let name = environment["\(prefix)_NAME"], let url = environment["\(prefix)_URL"],
                  let token = environment["\(prefix)_TOKEN"],
                  let normalized = try? Host.normalizedURL(url),
                  !hosts.contains(where: { $0.baseURL == normalized })
            else { continue }
            _ = try? add(name: name, url: url, token: token)
        }
    }

    private static func validated(name: String, url: String) throws -> (String, URL) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HostValidationError.emptyName }
        return (name, try Host.normalizedURL(url))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            persistence.save(data)
        }
    }
}
