import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4

struct SessionListLayoutTests {
    @Test func sectionsDansLOrdre() throws {
        let sessions = [
            try makeSummary("attente", pendingPermissions: 1),
            try makeSummary("epinglee"),
            try makeSummary("recente"),
        ]
        let layout = SessionListLayout(sessions: sessions, drafts: ["brouillon"], pinnedIds: ["epinglee"], query: "")
        #expect(layout.drafts == ["brouillon"])
        #expect(layout.waiting.map(\.sessionId) == ["attente"])
        #expect(layout.pinned.map(\.sessionId) == ["epinglee"])
        #expect(layout.recent.map(\.sessionId) == ["recente"])
        #expect(!layout.isEmpty)
    }

    @Test func epingleeEnAttenteSansDoublon() throws {
        let sessions = [try makeSummary("a", pendingPermissions: 2), try makeSummary("b")]
        let layout = SessionListLayout(sessions: sessions, drafts: [], pinnedIds: ["a"], query: "")
        #expect(layout.waiting.map(\.sessionId) == ["a"])
        #expect(layout.pinned.isEmpty)
        #expect(layout.recent.map(\.sessionId) == ["b"])
    }

    @Test func ordreDActiviteConserve() throws {
        let sessions = [try makeSummary("recente"), try makeSummary("ancienne")]          // déjà triées par l'index
        let layout = SessionListLayout(sessions: sessions, drafts: [], pinnedIds: [], query: "")
        #expect(layout.recent.map(\.sessionId) == ["recente", "ancienne"])
    }

    @Test func rechercheSansAccentsNiCasse() throws {
        let sessions = [
            try makeSummary("titre", title: "Réponse PONG"),
            try makeSummary("apercu", title: "Autre", preview: "J'ai corrigé l'écran"),
            try makeSummary("rien", title: "Divers"),
        ]
        func ids(_ query: String) -> [String] {
            SessionListLayout(sessions: sessions, drafts: [], pinnedIds: [], query: query).recent.map(\.sessionId)
        }
        #expect(ids("reponse") == ["titre"])
        #expect(ids("  pong ") == ["titre"])
        #expect(ids("ECRAN") == ["apercu"])
        #expect(ids("introuvable").isEmpty)
        #expect(SessionListLayout(sessions: sessions, drafts: [], pinnedIds: [], query: "introuvable").isEmpty)
    }

    @Test func sansTitreCherchable() throws {
        let sessions = [try makeSummary("vide", title: ""), try makeSummary("autre", title: "Divers")]
        func ids(_ query: String) -> [String] {
            SessionListLayout(sessions: sessions, drafts: [], pinnedIds: [], query: query).recent.map(\.sessionId)
        }
        #expect(SessionListLayout.untitledTitle == "Sans titre")
        #expect(ids("sans titre") == ["vide"])                                    // le libellé affiché est cherchable
        #expect(ids("Divers") == ["autre"])
    }

    @Test func brouillonsFiltres() throws {
        func drafts(_ query: String) -> [String] {
            SessionListLayout(sessions: [], drafts: ["d"], pinnedIds: [], query: query).drafts
        }
        #expect(drafts("") == ["d"])
        #expect(drafts("nouv") == ["d"])                                          // « Nouvelle session »
        #expect(drafts("pong").isEmpty)
    }
}
