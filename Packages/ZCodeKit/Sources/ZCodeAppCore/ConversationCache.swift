import Foundation
import Synchronization
import ZCodeV4
import ZCodeWire

/// Copie hors ligne (lot 13E-1) : fichiers bruts d'un cache local, jamais de token.
public protocol OfflineCacheStorage: Sendable {
    func read(_ name: String) -> Data?
    /// Écriture atomique, protection « jusqu'à la première authentification ».
    func write(_ data: Data, name: String)
    func remove(_ name: String)
    func removeAll()
}

/// Cache sur disque (Application Support, exclu des sauvegardes). Erreurs d'E/S avalées : cache au mieux.
public struct FileOfflineCacheStorage: OfflineCacheStorage {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func applicationSupport() -> FileOfflineCacheStorage {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return FileOfflineCacheStorage(directory: base.appending(path: "OfflineCache"))
    }

    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appending(path: name))
    }

    public func write(_ data: Data, name: String) {
        guard prepareDirectory() else { return }
        // Pas de protection complète : iPhone verrouillé (tâche d'arrière-plan), le manifeste paraîtrait absent et serait réécrit vide.
        try? data.write(to: directory.appending(path: name),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Crée le dossier au besoin et l'exclut des sauvegardes.
    private func prepareDirectory() -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = directory
            try? url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

/// Stockage en mémoire (tests, valeur par défaut).
public final class InMemoryOfflineCacheStorage: OfflineCacheStorage {
    private let files = Mutex<[String: Data]>([:])

    public init() {}

    public var names: [String] { files.withLock { Array($0.keys) } }

    public func read(_ name: String) -> Data? { files.withLock { $0[name] } }
    public func write(_ data: Data, name: String) { files.withLock { $0[name] = data } }
    public func remove(_ name: String) { files.withLock { _ = $0.removeValue(forKey: name) } }
    public func removeAll() { files.withLock { $0.removeAll() } }

    /// Pour les tests : remplace le contenu par des octets illisibles.
    public func corrupt(_ name: String) { files.withLock { $0[name] = Data("{".utf8) } }
}

public struct OfflineCopy<Value: Sendable>: Sendable {
    public let value: Value
    public let savedAt: Date
    public init(value: Value, savedAt: Date) { self.value = value; self.savedAt = savedAt }
}
extension OfflineCopy: Equatable where Value: Equatable {}

/// Conversations et listes de sessions gardées pour la lecture hors ligne (lot 13E-1).
/// Un fichier JSON par entrée et un manifeste ; bornes par hôte et en octets, éviction de la plus ancienne.
public actor ConversationCache {
    public static let maxConversationsPerHost = 20
    public static let maxBytes = 20_000_000

    private struct Entry: Codable {
        let hostId: UUID
        let workspace: String
        let sessionId: String?      // nil : liste des sessions du projet
        let file: String
        let savedAt: Date
        let bytes: Int
        func matches(hostId: UUID, workspace: String, sessionId: String?) -> Bool {
            self.hostId == hostId && self.workspace == workspace && self.sessionId == sessionId
        }
    }

    private static let manifestName = "manifest.json"
    private let storage: any OfflineCacheStorage
    private let maxConversationsPerHost: Int
    private let maxBytes: Int
    private var loaded: [Entry]?

    public init(storage: any OfflineCacheStorage = InMemoryOfflineCacheStorage(),
                maxConversationsPerHost: Int = ConversationCache.maxConversationsPerHost,
                maxBytes: Int = ConversationCache.maxBytes) {
        self.storage = storage
        self.maxConversationsPerHost = maxConversationsPerHost
        self.maxBytes = maxBytes
    }

    public func saveConversation(_ snapshot: ConversationSnapshot, key: SessionKey, savedAt: Date) {
        store(snapshot.offlineJSON(keepingLast: ConversationModel.historyPageSize),
              hostId: key.hostId, workspace: key.workspace, sessionId: key.sessionId, savedAt: savedAt)
    }

    public func conversation(_ key: SessionKey) -> OfflineCopy<ConversationSnapshot>? {
        load(hostId: key.hostId, workspace: key.workspace, sessionId: key.sessionId) { try ConversationSnapshot(json: $0) }
    }

    public func saveSessions(_ index: SessionsIndex, hidden: Set<String>, hostId: UUID, workspace: String, savedAt: Date) {
        guard let json = try? index.offlineJSON(excluding: hidden) else { return }
        store(json, hostId: hostId, workspace: workspace, sessionId: nil, savedAt: savedAt)
    }

    public func sessions(hostId: UUID, workspace: String) -> OfflineCopy<SessionsIndex>? {
        load(hostId: hostId, workspace: workspace, sessionId: nil) { try SessionsIndex(json: $0) }
    }

    public func remove(_ key: SessionKey) {
        var entries = currentEntries()
        guard let i = entries.firstIndex(where: { $0.matches(hostId: key.hostId, workspace: key.workspace, sessionId: key.sessionId) })
        else { return }
        storage.remove(entries[i].file)
        entries.remove(at: i)
        persist(entries)
    }

    /// Retire conversations et listes de l'hôte.
    public func removeAll(hostId: UUID) {
        let entries = currentEntries()
        for entry in entries where entry.hostId == hostId { storage.remove(entry.file) }
        persist(entries.filter { $0.hostId != hostId })
    }

    /// Octets gardés pour l'hôte (conversations et listes).
    public func bytes(hostId: UUID) -> Int {
        currentEntries().filter { $0.hostId == hostId }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Interne

    private func currentEntries() -> [Entry] {
        if let loaded { return loaded }
        var entries: [Entry] = []
        if let data = storage.read(Self.manifestName) {
            if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = decoded
            } else {
                storage.removeAll()     // manifeste illisible : on repart de zéro, fichiers orphelins compris
            }
        }
        loaded = entries
        return entries
    }

    private func persist(_ entries: [Entry]) {
        loaded = entries
        if let data = try? JSONEncoder().encode(entries) { storage.write(data, name: Self.manifestName) }
    }

    private func store(_ json: JSONValue, hostId: UUID, workspace: String, sessionId: String?, savedAt: Date) {
        guard let data = try? JSONEncoder().encode(json) else { return }
        var entries = currentEntries()
        let file = UUID().uuidString + ".json"
        storage.write(data, name: file)
        if let i = entries.firstIndex(where: { $0.matches(hostId: hostId, workspace: workspace, sessionId: sessionId) }) {
            storage.remove(entries[i].file)
            entries.remove(at: i)
        }
        entries.append(Entry(hostId: hostId, workspace: workspace, sessionId: sessionId,
                             file: file, savedAt: savedAt, bytes: data.count))
        // (1) bornes par hôte : conversations seulement.
        while entries.filter({ $0.hostId == hostId && $0.sessionId != nil }).count > maxConversationsPerHost,
              let oldest = entries.enumerated()
                .filter({ $0.element.hostId == hostId && $0.element.sessionId != nil })
                .min(by: { $0.element.savedAt < $1.element.savedAt }) {
            storage.remove(oldest.element.file)
            entries.remove(at: oldest.offset)
        }
        // (2) borne en octets : toutes sortes confondues.
        while entries.reduce(0, { $0 + $1.bytes }) > maxBytes,
              let oldest = entries.enumerated().min(by: { $0.element.savedAt < $1.element.savedAt }) {
            storage.remove(oldest.element.file)
            entries.remove(at: oldest.offset)
        }
        persist(entries)
    }

    private func load<Value: Sendable>(hostId: UUID, workspace: String, sessionId: String?,
                                       decode: (JSONValue) throws -> Value) -> OfflineCopy<Value>? {
        let entries = currentEntries()
        guard let entry = entries.first(where: { $0.matches(hostId: hostId, workspace: workspace, sessionId: sessionId) })
        else { return nil }
        if let data = storage.read(entry.file),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           let value = try? decode(json) {
            return OfflineCopy(value: value, savedAt: entry.savedAt)
        }
        storage.remove(entry.file)
        persist(entries.filter { $0.file != entry.file })
        return nil
    }
}
