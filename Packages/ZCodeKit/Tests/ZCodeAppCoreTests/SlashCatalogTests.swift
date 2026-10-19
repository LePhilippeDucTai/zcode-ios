import Foundation
import Synchronization
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Méthode de lecture des commandes, construite sur le canal du client.
private let presentationMethod = "\(ComposerCatalogClient.presentationChannel).readWorkspacePresentation"

/// Horloge des tests du cache.
final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_791_890_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

@MainActor
struct SlashCatalogTests {
    func catalogServer(skillsFail: Bool = false) async throws -> FakeZCodeServer {
        let server = try await readyServer()
        await server.on(presentationMethod) { _ in
            .object(["slashCommands": .array([
                .object(["name": .string("goal"), "description": .string("Objectif")]),
                .object(["name": .string("compact"), "description": .string("Compresse")]),
            ])])
        }
        await server.on("zcode-agent.getSkillReferenceCatalog") { argument in
            if skillsFail, argument["sessionId"] != nil { throw FakeRemoteError("Unknown session") }
            return .object(["authority": .string(argument["sessionId"] == nil ? "workspace" : "session"), "skills": .array([
                .object(["id": .string("w"), "name": .string("revue"), "path": .string("/w/.zcode/skills/revue/SKILL.md"),
                         "scope": .string("workspace"), "description": .string("Relit")]),
            ])])
        }
        await server.on("subagents.list") { _ in
            .object(["agents": .array([.object([
                "id": .string("built-in:built-in:explore"), "name": .string("Explore"), "path": .string("built-in:Explore"),
                "description": .string("Explore"), "systemPrompt": .string("s"), "scope": .string("built-in"),
                "source": .string("built-in"), "enabled": .bool(true),
            ])])])
        }
        return server
    }

    func makeCatalog(_ server: FakeZCodeServer, clock: TestClock = TestClock(), fallback: Bool = false) -> SlashCatalog {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        return SlashCatalog(connection: connection, workspace: testWorkspacePath,
                            subagents: SubagentsModel(connection: connection, scope: .workspace(testWorkspacePath)),
                            skillsFallback: fallback, now: { clock.now })
    }

    @Test func catalogueReuniDesTroisSources() async throws {
        let server = try await catalogServer()
        let catalog = makeCatalog(server)
        await catalog.refreshIfNeeded(sessionId: nil)
        let sections = catalog.sections(query: "", sessionId: nil)
        #expect(sections.map(\.title) == ["Commandes", "Skills", "Sous-agents"])
        #expect(sections.map { $0.entries.map(\.insertion) } == [["/goal", "/compact"], ["$revue"], ["@Explore"]])
        #expect(await server.calls(to: presentationMethod) == [.object(["workspacePath": .string(testWorkspacePath)])])
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog") == [.object(["workspacePath": .string(testWorkspacePath)])])
        #expect(!catalog.isLoading)
    }

    @Test func relectureApresCinqMinutes() async throws {
        let server = try await catalogServer()
        let clock = TestClock()
        let catalog = makeCatalog(server, clock: clock)
        await catalog.refreshIfNeeded(sessionId: nil)
        clock.advance(299)
        await catalog.refreshIfNeeded(sessionId: nil)
        #expect(await server.calls(to: presentationMethod).count == 1)
        clock.advance(2)
        await catalog.refreshIfNeeded(sessionId: nil)
        #expect(await server.calls(to: presentationMethod).count == 2)
    }

    @Test func skillsDeLaSessionSansRelireLeProjet() async throws {
        let server = try await catalogServer()
        let catalog = makeCatalog(server)
        await catalog.refreshIfNeeded(sessionId: nil)
        await catalog.refreshIfNeeded(sessionId: "sess_1")                     // projet frais : skills seules
        #expect(await server.calls(to: presentationMethod).count == 1)
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog").last
            == .object(["workspacePath": .string(testWorkspacePath), "sessionId": .string("sess_1")]))
        #expect(catalog.skills(sessionId: "sess_1")?.map(\.name) == ["revue"])
    }

    @Test func sourceEnEchecRetireSaSection() async throws {
        let server = try await catalogServer(skillsFail: true)
        let catalog = makeCatalog(server)
        await catalog.refreshIfNeeded(sessionId: "sess_ancienne")
        #expect(catalog.sections(query: "", sessionId: "sess_ancienne").map(\.title) == ["Commandes", "Sous-agents"])
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog").count == 1)    // aucun repli (comme le web)
        await catalog.refreshIfNeeded(sessionId: "sess_ancienne")                             // échec : relu au prochain geste
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog").count == 2)
    }

    @Test func secoursDuProjetSiDecide() async throws {
        let server = try await catalogServer(skillsFail: true)
        let catalog = makeCatalog(server, fallback: true)
        await catalog.refreshIfNeeded(sessionId: "sess_ancienne")
        #expect(catalog.skills(sessionId: "sess_ancienne")?.map(\.name) == ["revue"])
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog").last == .object(["workspacePath": .string(testWorkspacePath)]))
    }

    @Test func sousAgentsIllisiblesRelusSansAttendreCinqMinutes() async throws {
        let server = try await catalogServer()
        await server.on("subagents.list") { _ in throw FakeRemoteError("indisponible") }
        let catalog = makeCatalog(server)
        await catalog.refreshIfNeeded(sessionId: nil)
        #expect(catalog.subagents == nil)
        await server.on("subagents.list") { _ in
            .object(["agents": .array([.object([
                "id": .string("built-in:built-in:explore"), "name": .string("Explore"), "path": .string("built-in:Explore"),
                "description": .string("Explore"), "systemPrompt": .string("s"), "scope": .string("built-in"),
                "source": .string("built-in"), "enabled": .bool(true),
            ])])])
        }
        await catalog.refreshIfNeeded(sessionId: nil)                                  // même horloge : relu quand même
        #expect(catalog.subagents?.map(\.name) == ["Explore"])
    }

    /// Attend que `canal.méthode` ait reçu `count` appels.
    private func waitForCalls(_ server: FakeZCodeServer, _ method: String, count: Int) async throws {
        for _ in 0..<500 {
            if await server.calls(to: method).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("appel \(method) jamais reçu")
    }

    @Test func appelsQuiSeChevauchentLisentChaqueAutorite() async throws {
        let server = try await catalogServer()
        await server.onDeferred(presentationMethod)
        let catalog = makeCatalog(server)
        let first = Task { await catalog.refreshIfNeeded(sessionId: nil) }
        try await waitForCalls(server, presentationMethod, count: 1)               // lecture du projet en cours
        let second = Task { await catalog.refreshIfNeeded(sessionId: "sess_1") }   // l'autorité change pendant la lecture
        try await Task.sleep(for: .milliseconds(50))
        await server.respondDeferred(presentationMethod, .object(["slashCommands": .array([])]))
        await first.value
        await second.value
        #expect(catalog.skills(sessionId: nil)?.map(\.name) == ["revue"])
        #expect(catalog.skills(sessionId: "sess_1")?.map(\.name) == ["revue"])
        let calls = await server.calls(to: "zcode-agent.getSkillReferenceCatalog")
        #expect(calls.contains(.object(["workspacePath": .string(testWorkspacePath), "sessionId": .string("sess_1")])))
        #expect(calls.contains(.object(["workspacePath": .string(testWorkspacePath)])))
        #expect(await server.calls(to: presentationMethod).count == 1)
    }

    @Test func annulerLAppelantNeVidePasLeCatalogue() async throws {
        let server = try await catalogServer()
        await server.onDeferred(presentationMethod)
        let catalog = makeCatalog(server)
        let caller = Task { await catalog.refreshIfNeeded(sessionId: nil) }
        try await waitForCalls(server, presentationMethod, count: 1)
        caller.cancel()                                                             // la vue disparaît ou change de tâche
        await server.respondDeferred(presentationMethod, .object(["slashCommands": .array([
            .object(["name": .string("goal"), "description": .string("Objectif")]),
        ])]))
        await caller.value
        #expect(catalog.commands?.map(\.insertion) == ["/goal"])
        #expect(catalog.skills(sessionId: nil)?.map(\.name) == ["revue"])
        #expect(!catalog.isLoading)
    }
}
