import Foundation
import Testing
import ZCodeAppCore

@MainActor
struct SeenStoreTests {
    let hostId = UUID()
    func key(_ sessionId: String, workspace: String = "/w") -> SessionKey {
        SessionKey(hostId: hostId, workspace: workspace, sessionId: sessionId)
    }

    @Test func sansReferenceRienNEstNonLu() {
        let store = SeenStore()
        #expect(!store.isUnread(key("a"), lastActivityAt: 9_999))                  // projet jamais chargé
    }

    @Test func premierChargementToutLu() {
        let store = SeenStore()
        store.establishBaseline(hostId: hostId, workspace: "/w", lastActivities: [100, 200])
        #expect(!store.isUnread(key("a"), lastActivityAt: 200))
        #expect(!store.isUnread(key("ancienne"), lastActivityAt: 150))
        #expect(store.isUnread(key("nouvelle"), lastActivityAt: 250))            // apparue ou active depuis
        store.establishBaseline(hostId: hostId, workspace: "/w", lastActivities: [900])   // une seule fois
        #expect(store.isUnread(key("nouvelle"), lastActivityAt: 250))
    }

    @Test func vueJusquALaDerniereActivite() {
        let store = SeenStore()
        store.markSeen(key("a"), at: 300)
        #expect(!store.isUnread(key("a"), lastActivityAt: 300))
        #expect(store.isUnread(key("a"), lastActivityAt: 301))
        store.markSeen(key("a"), at: 200)                                          // jamais en arrière
        #expect(store.lastSeen(key("a")) == 300)
    }

    @Test func ouverteJamaisNonLue() {
        let store = SeenStore()
        store.markSeen(key("a"), at: 100)
        store.didOpen(key("a"))
        #expect(!store.isUnread(key("a"), lastActivityAt: 999))
        store.didClose(key("a"), at: 500)
        #expect(!store.isUnread(key("a"), lastActivityAt: 500))
        #expect(store.isUnread(key("a"), lastActivityAt: 600))
    }

    @Test func persistance() {
        let persistence = InMemoryLocalPersistence()
        let store = SeenStore(persistence: persistence)
        store.establishBaseline(hostId: hostId, workspace: "/w", lastActivities: [100])
        store.markSeen(key("a"), at: 300)
        store.didOpen(key("b"))
        let reloaded = SeenStore(persistence: persistence)
        #expect(reloaded.lastSeen(key("a")) == 300)
        #expect(reloaded.isUnread(key("c"), lastActivityAt: 101))                 // référence relue
        #expect(reloaded.isUnread(key("b"), lastActivityAt: 101))                 // l'ouverture n'est pas persistée
    }

    @Test func menageParProjet() {
        let store = SeenStore()
        store.markSeen(key("a"), at: 1)
        store.markSeen(key("b"), at: 1)
        store.markSeen(key("a", workspace: "/autre"), at: 1)
        store.prune(hostId: hostId, workspace: "/w", keeping: ["a"])
        #expect(store.lastSeen(key("a")) == 1)
        #expect(store.lastSeen(key("b")) == nil)
        #expect(store.lastSeen(key("a", workspace: "/autre")) == 1)               // autre projet intact
    }
}
