import Foundation
import Observation

/// Sessions épinglées en tête de la liste de leur projet, tenues sur cet iPhone.
@MainActor
@Observable
public final class PinStore {
    public static let storageKey = "zcode-pins:v1"

    /// `SessionKey.storageKey` des sessions épinglées.
    private var pinned: Set<String>
    @ObservationIgnored private let persistence: any LocalPersistence

    public init(persistence: any LocalPersistence = InMemoryLocalPersistence()) {
        self.persistence = persistence
        pinned = Set(persistence.load().flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    public func isPinned(_ key: SessionKey) -> Bool {
        pinned.contains(key.storageKey)
    }

    public func setPinned(_ isPinned: Bool, _ key: SessionKey) {
        let changed = isPinned ? pinned.insert(key.storageKey).inserted : pinned.remove(key.storageKey) != nil
        if changed { save() }
    }

    /// Identifiants des sessions épinglées d'un projet.
    public func pinnedIds(hostId: UUID, workspace: String) -> Set<String> {
        let prefix = SessionKey.projectPrefix(hostId: hostId, workspace: workspace)
        return Set(pinned.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// Retire les épingles des sessions disparues de la liste du projet (supprimées, archivées).
    public func prune(hostId: UUID, workspace: String, keeping sessionIds: Set<String>) {
        let stale = SessionKey.staleKeys(in: pinned, hostId: hostId, workspace: workspace, keeping: sessionIds)
        guard !stale.isEmpty else { return }
        pinned.subtract(stale)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pinned.sorted()) {
            persistence.save(data)
        }
    }
}
