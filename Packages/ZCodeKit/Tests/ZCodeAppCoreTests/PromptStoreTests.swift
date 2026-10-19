import Foundation
import Testing
import ZCodeAppCore

@MainActor
struct PromptStoreTests {
    @Test func ajoutTitreParDefautEtPersistance() throws {
        let persistence = InMemoryLocalPersistence()
        let store = PromptStore(persistence: persistence)
        let first = try #require(store.add(title: "  ", text: "Relis le diff\net propose des tests"))
        #expect(first.title == "Relis le diff")
        #expect(store.add(title: "Vide", text: " \n ") == nil)
        store.add(title: "Tests", text: "Lance swift test")
        #expect(PromptStore(persistence: persistence).favorites.map(\.title) == ["Relis le diff", "Tests"])
        #expect(PromptStore.defaultTitle(for: String(repeating: "x", count: 80)).count == PromptStore.maxTitleLength)
    }

    @Test func modificationEtSuppression() throws {
        let store = PromptStore()
        let favorite = try #require(store.add(title: "A", text: "a"))
        #expect(store.update(favorite.id, title: "B", text: "b"))
        #expect(store.favorites == [PromptFavorite(id: favorite.id, title: "B", text: "b")])
        #expect(!store.update(favorite.id, title: "C", text: "  "))             // texte vide refusé
        #expect(!store.update(UUID(), title: "C", text: "c"))
        store.remove(favorite.id)
        #expect(store.favorites.isEmpty)
    }

    @Test func reordonnerCommeSwiftUI() {
        let store = PromptStore()
        for title in ["a", "b", "c", "d"] { store.add(title: title, text: title) }
        store.move(from: [0], to: 3)
        #expect(store.favorites.map(\.title) == ["b", "c", "a", "d"])
        store.move(from: [3], to: 0)
        #expect(store.favorites.map(\.title) == ["d", "b", "c", "a"])
        store.move(from: [1, 2], to: 4)
        #expect(store.favorites.map(\.title) == ["d", "a", "b", "c"])
    }

    @Test func insertionDansLeBrouillon() {
        #expect(PromptStore.inserting("Relis", into: "") == "Relis")
        #expect(PromptStore.inserting("Relis", into: "  \n") == "Relis")              // brouillon vide : remplacé
        #expect(PromptStore.inserting("Relis", into: "Bonjour") == "Bonjour\nRelis")   // sinon : à la suite
        #expect(PromptStore.inserting("Relis", into: "Bonjour\n") == "Bonjour\nRelis")
    }
}
