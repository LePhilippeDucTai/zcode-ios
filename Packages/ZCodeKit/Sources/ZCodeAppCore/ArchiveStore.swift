import Foundation
import Observation
import Synchronization

public protocol ArchivePersistence: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

public struct UserDefaultsArchivePersistence: ArchivePersistence {
    public static let key = "zcode-archives:v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> Data? { defaults.data(forKey: Self.key) }
    public func save(_ data: Data) { defaults.set(data, forKey: Self.key) }
}

public final class InMemoryArchivePersistence: ArchivePersistence {
    private let data = Mutex<Data?>(nil)

    public init() {}

    public func load() -> Data? { data.withLock { $0 } }
    public func save(_ data: Data) { self.data.withLock { $0 = data } }
}

/// Une conversation archivée depuis cet iPhone. La date locale d'archivage pilote la suppression définitive :
/// l'hôte n'écrit pas de date d'archivage dans son index (`updatedAt` reste la dernière activité).
public struct ArchiveEntry: Codable, Equatable, Sendable {
    public let hostId: UUID
    public let workspace: String
    public let sessionId: String
    public let archivedAt: Date
}

/// Dates d'archivage connues de l'app, par hôte et projet. Pour une conversation archivée ailleurs (interface web),
/// la première vue par l'app devient la date de référence du délai.
@MainActor
public final class ArchiveStore {
    public private(set) var entries: [ArchiveEntry]
    private let persistence: any ArchivePersistence

    public init(persistence: any ArchivePersistence = InMemoryArchivePersistence()) {
        self.persistence = persistence
        entries = persistence.load().flatMap { try? JSONDecoder().decode([ArchiveEntry].self, from: $0) } ?? []
    }

    public func entries(hostId: UUID, workspace: String) -> [ArchiveEntry] {
        entries.filter { $0.hostId == hostId && $0.workspace == workspace }
    }

    public func archivedAt(hostId: UUID, workspace: String, sessionId: String) -> Date? {
        entries.first { $0.hostId == hostId && $0.workspace == workspace && $0.sessionId == sessionId }?.archivedAt
    }

    /// Inchange si une entrée existe déjà (la date d'origine du délai est conservée).
    public func record(hostId: UUID, workspace: String, sessionId: String, at date: Date) {
        guard archivedAt(hostId: hostId, workspace: workspace, sessionId: sessionId) == nil else { return }
        entries.append(ArchiveEntry(hostId: hostId, workspace: workspace, sessionId: sessionId, archivedAt: date))
        save()
    }

    public func remove(hostId: UUID, workspace: String, sessionId: String) {
        entries.removeAll { $0.hostId == hostId && $0.workspace == workspace && $0.sessionId == sessionId }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            persistence.save(data)
        }
    }
}
