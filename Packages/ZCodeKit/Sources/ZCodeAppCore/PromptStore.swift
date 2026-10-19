import Foundation
import Observation

/// Prompt favori : titre et texte, communs à tous les hôtes.
public struct PromptFavorite: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var text: String

    public init(id: UUID, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Prompts favoris tenus sur cet iPhone (UserDefaults, `zcode-prompts:v1`), communs à tous les hôtes.
@MainActor
@Observable
public final class PromptStore {
    public static let storageKey = "zcode-prompts:v1"
    public static let maxTitleLength = 60

    public private(set) var favorites: [PromptFavorite]
    @ObservationIgnored private let persistence: any LocalPersistence

    public init(persistence: any LocalPersistence = InMemoryLocalPersistence()) {
        self.persistence = persistence
        favorites = persistence.load().flatMap { try? JSONDecoder().decode([PromptFavorite].self, from: $0) } ?? []
    }

    /// Titre vide : première ligne du texte ; texte blanc : refusé (`nil`).
    @discardableResult
    public func add(title: String, text: String) -> PromptFavorite? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let favorite = PromptFavorite(id: UUID(), title: Self.title(title, for: text), text: text)
        favorites.append(favorite)
        save()
        return favorite
    }

    @discardableResult
    public func update(_ id: UUID, title: String, text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = favorites.firstIndex(where: { $0.id == id }) else { return false }
        favorites[index].title = Self.title(title, for: text)
        favorites[index].text = text
        save()
        return true
    }

    public func remove(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        save()
    }

    /// Même sens que `onMove` de SwiftUI : `destination` est une position de la liste d'avant le déplacement.
    public func move(from source: IndexSet, to destination: Int) {
        let moving = source.filter { favorites.indices.contains($0) }.map { favorites[$0] }
        guard !moving.isEmpty else { return }
        let above = source.filter { $0 < destination }.count
        var rest = favorites.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: min(max(destination - above, 0), rest.count))
        favorites = rest
        save()
    }

    /// Première ligne non vide du texte, bornée à `maxTitleLength` caractères.
    public static func defaultTitle(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(maxTitleLength))
    }

    /// Brouillon vide : le favori le remplace ; sinon il est ajouté à la ligne.
    public static func inserting(_ text: String, into draft: String) -> String {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return draft + (draft.hasSuffix("\n") ? "" : "\n") + text
    }

    private static func title(_ title: String, for text: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultTitle(for: text) : String(trimmed.prefix(maxTitleLength))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            persistence.save(data)
        }
    }
}
