import Foundation
import ZCodeV4

/// Sections de la liste des sessions d'un projet : brouillons, « En attente de vous », « Épinglées », « Récentes ».
/// Une session n'apparaît qu'une fois (l'attente passe avant l'épingle) ; l'ordre d'activité reçu est conservé.
public struct SessionListLayout: Equatable, Sendable {
    /// Libellé d'un brouillon dans la liste (la recherche le compare aussi).
    public static let draftTitle = "Nouvelle session"

    /// Libellé d'une session sans titre dans la liste (la recherche le compare aussi).
    public static let untitledTitle = "Sans titre"

    public let drafts: [String]
    public let waiting: [SessionSummary]
    public let pinned: [SessionSummary]
    public let recent: [SessionSummary]

    public var isEmpty: Bool { drafts.isEmpty && waiting.isEmpty && pinned.isEmpty && recent.isEmpty }

    /// `sessions` : sessions visibles, déjà triées par activité récente ; `query` : texte de recherche (vide : tout).
    public init(sessions: [SessionSummary], drafts: [String], pinnedIds: Set<String>, query: String) {
        let needle = Self.normalized(query)
        let visible = needle.isEmpty ? sessions : sessions.filter { summary in
            Self.normalized(summary.title.isEmpty ? Self.untitledTitle : summary.title).contains(needle)
                || Self.normalized(summary.lastAssistantPreview ?? "").contains(needle)
        }
        waiting = visible.filter { $0.pendingCount > 0 }
        pinned = visible.filter { $0.pendingCount == 0 && pinnedIds.contains($0.sessionId) }
        recent = visible.filter { $0.pendingCount == 0 && !pinnedIds.contains($0.sessionId) }
        self.drafts = needle.isEmpty || Self.normalized(Self.draftTitle).contains(needle) ? drafts : []
    }

    /// Casse et accents ignorés, espaces de bord retirés.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
