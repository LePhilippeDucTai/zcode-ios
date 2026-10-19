import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Vue synthétique avec la révision voulue.
func catalogView(revision: Int) throws -> JSONValue {
    var view = try #require(Fixtures.file("synthetic/model-selection-mistral.json").objectValue)
    view["revision"] = .number(Double(revision))
    return .object(view)
}

func catalogServer(revisions: Recorder<Int>) async throws -> FakeZCodeServer {
    let server = try await readyServer()
    let counter = Counter()
    await server.on("model-selection.getView") { _ in
        // Révisions servies dans l'ordre enregistré ; la dernière se répète.
        let index = counter.next() - 1
        let all = revisions.all
        return try catalogView(revision: all[min(index, all.count - 1)])
    }
    return server
}

@MainActor
struct ModelCatalogTests {
    func makeCatalog(_ servers: ServerQueue) -> ModelCatalog {
        ModelCatalog(connection: HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers)))
    }

    @Test func chargementPuisChangement() async throws {
        let revisions = Recorder<Int>()
        [4, 6, 5].forEach(revisions.append)
        let server = try await catalogServer(revisions: revisions)
        let catalog = makeCatalog(ServerQueue([server]))
        await catalog.start()
        #expect(catalog.view?.revision == 4)
        #expect(catalog.view?.provider(id: "new-provider")?.name == "Mistral")
        _ = try await eventually { await server.listenerCount("model-selection.onDidChange") == 1 ? true : nil }
        await server.emit("model-selection.onDidChange", .null)                // fournisseur ajouté sur le Mac
        _ = try await eventually { catalog.view?.revision == 6 ? true : nil }
        await server.emit("model-selection.onDidChange", .null)                // réponse plus ancienne : ignorée
        _ = try await eventually { await server.calls(to: "model-selection.getView").count == 3 ? true : nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(catalog.view?.revision == 6)
    }

    @Test func nouvelleConnexionAccepteUneRevisionPlusBasse() async throws {
        let high = Recorder<Int>()
        high.append(9)
        let low = Recorder<Int>()
        low.append(1)                                                          // ZCode redémarré : compteur à zéro
        let first = try await catalogServer(revisions: high)
        let second = try await catalogServer(revisions: low)
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([first, second])))
        let catalog = ModelCatalog(connection: connection)
        await catalog.start()
        #expect(catalog.view?.revision == 9)
        first.transport.finish()
        _ = try await eventually { await connection.isAlive() ? nil : true }   // la chute doit être vue avant la relance
        await catalog.start()                                                  // nouvelle connexion (premier plan, ouverture)
        _ = try await eventually { catalog.view?.revision == 1 ? true : nil }
    }

    @Test func echecDuChargementRetenteParStartIfNeeded() async throws {
        struct Unavailable: Error {}
        let server = try await readyServer()
        let counter = Counter()
        await server.on("model-selection.getView") { _ in
            if counter.next() == 1 { throw Unavailable() }                     // premier chargement en échec
            return try catalogView(revision: 4)
        }
        let catalog = makeCatalog(ServerQueue([server]))
        await catalog.start()
        #expect(catalog.failure != nil)
        #expect(catalog.view == nil)
        await catalog.startIfNeeded()                                          // ouverture d'un écran / premier plan
        _ = try await eventually { catalog.view?.revision == 4 ? true : nil }
        #expect(catalog.failure == nil)
    }
}
