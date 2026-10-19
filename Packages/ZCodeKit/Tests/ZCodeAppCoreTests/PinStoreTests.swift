import Foundation
import Testing
import ZCodeAppCore

@MainActor
struct PinStoreTests {
    let hostId = UUID()
    func key(_ sessionId: String, workspace: String = "/w") -> SessionKey {
        SessionKey(hostId: hostId, workspace: workspace, sessionId: sessionId)
    }

    @Test func epinglerPuisRetirer() {
        let persistence = InMemoryLocalPersistence()
        let store = PinStore(persistence: persistence)
        store.setPinned(true, key("a"))
        store.setPinned(true, key("b", workspace: "/autre"))
        #expect(store.isPinned(key("a")))
        #expect(store.pinnedIds(hostId: hostId, workspace: "/w") == ["a"])
        #expect(PinStore(persistence: persistence).isPinned(key("a")))           // relu
        store.setPinned(false, key("a"))
        #expect(!store.isPinned(key("a")))
        #expect(PinStore(persistence: persistence).pinnedIds(hostId: hostId, workspace: "/w").isEmpty)
    }

    @Test func menageParProjet() {
        let store = PinStore()
        store.setPinned(true, key("a"))
        store.setPinned(true, key("b"))
        store.setPinned(true, key("b", workspace: "/autre"))
        store.prune(hostId: hostId, workspace: "/w", keeping: ["a"])
        #expect(store.pinnedIds(hostId: hostId, workspace: "/w") == ["a"])
        #expect(store.isPinned(key("b", workspace: "/autre")))
    }
}
