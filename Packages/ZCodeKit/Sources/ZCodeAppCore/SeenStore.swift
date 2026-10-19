import Foundation
import Observation

/// Dernière activité vue de chaque session (pastille « non lu »), tenue sur cet iPhone. Les dates sont celles de
/// l'index de l'hôte (`lastActivityAt`, en millisecondes).
@MainActor
@Observable
public final class SeenStore {
    public static let storageKey = "zcode-seen:v1"

    private struct Stored: Codable {
        /// `SessionKey.storageKey` → dernière activité vue.
        var seen: [String: Double] = [:]
        /// `SessionKey.projectPrefix` → activité la plus récente au premier chargement de la liste du projet.
        var baselines: [String: Double] = [:]
    }

    private var stored: Stored
    /// Conversations affichées : jamais « non lues » (non persisté).
    public private(set) var openSessions: Set<SessionKey> = []
    @ObservationIgnored private let persistence: any LocalPersistence

    public init(persistence: any LocalPersistence = InMemoryLocalPersistence()) {
        self.persistence = persistence
        stored = persistence.load().flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// Une session sans entrée n'est non lue que si elle a bougé depuis le premier chargement de son projet ; un projet
    /// jamais chargé n'a rien de non lu.
    public func isUnread(_ key: SessionKey, lastActivityAt: Double) -> Bool {
        guard !openSessions.contains(key) else { return false }
        if let seenAt = stored.seen[key.storageKey] { return lastActivityAt > seenAt }
        guard let baseline = stored.baselines[SessionKey.projectPrefix(hostId: key.hostId, workspace: key.workspace)]
        else { return false }
        return lastActivityAt > baseline
    }

    /// Premier chargement de la liste d'un projet sur cet iPhone : tout ce qui existe déjà compte comme lu.
    public func establishBaseline(hostId: UUID, workspace: String, lastActivities: [Double]) {
        let project = SessionKey.projectPrefix(hostId: hostId, workspace: workspace)
        guard stored.baselines[project] == nil else { return }
        stored.baselines[project] = lastActivities.max() ?? 0
        save()
    }

    /// Ne recule jamais (un index en retard ne rend pas une session « non lue »).
    public func markSeen(_ key: SessionKey, at activityAt: Double) {
        guard activityAt > (stored.seen[key.storageKey] ?? -.infinity) else { return }
        stored.seen[key.storageKey] = activityAt
        save()
    }

    public func lastSeen(_ key: SessionKey) -> Double? {
        stored.seen[key.storageKey]
    }

    public func didOpen(_ key: SessionKey) {
        openSessions.insert(key)
    }

    public func didClose(_ key: SessionKey, at activityAt: Double) {
        openSessions.remove(key)
        markSeen(key, at: activityAt)
    }

    /// Retire les sessions disparues de la liste du projet (supprimées, archivées).
    public func prune(hostId: UUID, workspace: String, keeping sessionIds: Set<String>) {
        let stale = SessionKey.staleKeys(in: stored.seen.keys, hostId: hostId, workspace: workspace, keeping: sessionIds)
        guard !stale.isEmpty else { return }
        for key in stale { stored.seen[key] = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            persistence.save(data)
        }
    }
}
