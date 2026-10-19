import Foundation
import ZCodeV4

/// Recherche dans les lignes **chargées** d'une conversation (l'hôte n'offre pas de recherche) : correspondances dans
/// l'ordre chronologique, sélection gardée par identifiant d'entrée (une page plus ancienne s'insère devant).
public struct ConversationSearch: Equatable, Sendable {
    public private(set) var query = ""
    /// Entrées qui contiennent la requête, de la plus ancienne à la plus récente.
    public private(set) var matches: [Int] = []
    public private(set) var currentIndex: Int?
    /// Entrée à sélectionner dès qu'elle est parmi les correspondances (« Chercher plus loin »).
    private var wanted: Int?

    public init() {}

    public var currentId: Int? { currentIndex.map { matches[$0] } }

    /// « 3/12 », « Aucun résultat », ou `nil` sans requête.
    public var counter: String? {
        guard !SessionListLayout.normalized(query).isEmpty else { return nil }
        guard let currentIndex else { return "Aucun résultat" }
        return "\(currentIndex + 1)/\(matches.count)"
    }

    /// Nouvelle requête : la correspondance la plus récente (la plus proche du bas de l'écran) est sélectionnée.
    public mutating func update(query: String, entries: [ChatEntry]) {
        self.query = query
        wanted = nil
        matches = Self.matchingIds(in: entries, query: query)
        currentIndex = matches.isEmpty ? nil : matches.count - 1
    }

    /// Entrées changées (delta, page plus ancienne) : même requête ; la sélection reste sur la même entrée si elle
    /// existe encore, sinon la plus récente.
    public mutating func refresh(entries: [ChatEntry]) {
        let previous = currentId
        matches = Self.matchingIds(in: entries, query: query)
        if let wanted, let index = matches.firstIndex(of: wanted) {
            currentIndex = index
            self.wanted = nil
        } else if let previous, let index = matches.firstIndex(of: previous) {
            currentIndex = index
        } else {
            currentIndex = matches.isEmpty ? nil : matches.count - 1
        }
    }

    /// Sélectionne l'entrée `id` : tout de suite si elle est parmi les correspondances, sinon au prochain `refresh`.
    public mutating func select(_ id: Int) {
        if let index = matches.firstIndex(of: id) {
            currentIndex = index
            wanted = nil
        } else {
            wanted = id
        }
    }

    /// Correspondance plus ancienne (vers le haut), en boucle.
    public mutating func previous() {
        guard let currentIndex else { return }
        self.currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    /// Correspondance plus récente (vers le bas), en boucle.
    public mutating func next() {
        guard let currentIndex else { return }
        self.currentIndex = (currentIndex + 1) % matches.count
    }

    /// Identifiants des entrées qui contiennent `query`, casse et accents ignorés.
    public static func matchingIds(in entries: [ChatEntry], query: String) -> [Int] {
        let needle = SessionListLayout.normalized(query)
        guard !needle.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard case .item(let item) = entry.content, let text = searchableText(item) else { return nil }
            return SessionListLayout.normalized(text).contains(needle) ? entry.id : nil
        }
    }

    /// Messages, réponses, et pour un outil son nom avec sa commande ou son chemin (`ToolCall.summary`), plus le titre
    /// du sous-agent affiché sur sa carte (surnom, description) ; ni le
    /// raisonnement ni les pieds de tour.
    static func searchableText(_ item: ChatItem) -> String? {
        switch item {
        case .user(_, let input): input.text
        case .assistant(_, let answer): answer.text
        case .tool(_, let call, let link): [call.toolName, call.summary, link?.title].compactMap { $0 }.joined(separator: " ")
        default: nil
        }
    }
}
