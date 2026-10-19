import Foundation
import Testing
import ZCodeAppCore

/// Phase 12 : fenêtre de session (lieu, titre, utilisation).
@MainActor
struct SessionWindowTests {
    @Test func lieuDeLaSession() {
        #expect(ChatLabels.location(hostName: "MacBook Pro", workspace: "/Users/me/claude") == "MacBook Pro · claude")
        #expect(ChatLabels.location(hostName: "Steam Machine", workspace: "/home/deck/claude/") == "Steam Machine · claude")
        #expect(ChatLabels.location(hostName: "Mac", workspace: "/") == "Mac · /")
    }

    @Test func titreNormalise() {
        #expect(SessionTitle.normalized("  Refonte du chat  ", current: "Sans titre") == "Refonte du chat")
        #expect(SessionTitle.normalized("Deux\nlignes", current: nil) == "Deux lignes")
        #expect(SessionTitle.normalized("   ", current: "A") == nil)            // vide : rien à envoyer
        #expect(SessionTitle.normalized("A ", current: "A") == nil)            // inchangé
    }
}
