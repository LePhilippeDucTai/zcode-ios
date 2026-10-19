import Foundation
import Testing
import ZCodeAppCore

struct KeychainTokenStoreTests {
    @Test func ecritureRemplacementSuppression() throws {
        let store = KeychainTokenStore()
        let host = UUID()
        defer { store.removeToken(for: host) }
        #expect(store.token(for: host) == nil)
        try store.setToken("premier", for: host)
        #expect(store.token(for: host) == "premier")
        try store.setToken("second", for: host)                        // remplacement, pas de doublon
        #expect(store.token(for: host) == "second")
        store.removeToken(for: host)
        #expect(store.token(for: host) == nil)
    }

    @Test func unTokenParHote() throws {
        let store = KeychainTokenStore()
        let (first, second) = (UUID(), UUID())
        defer {
            store.removeToken(for: first)
            store.removeToken(for: second)
        }
        try store.setToken("a", for: first)
        try store.setToken("b", for: second)
        #expect(store.token(for: first) == "a")
        #expect(store.token(for: second) == "b")
    }
}
