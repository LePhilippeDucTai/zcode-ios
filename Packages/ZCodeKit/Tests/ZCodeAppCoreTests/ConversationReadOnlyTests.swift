import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationReadOnlyTests {
    func control(_ phase: String, canStop: Bool) -> JSONValue {
        .object(["phase": .string(phase), "canStop": .bool(canStop), "activeWorks": .array([])])
    }

    func goalAvailability() -> JSONValue {
        .object(["pauseGoal": .object(["allowed": .bool(true)]), "resumeGoal": .object(["allowed": .bool(true)])])
    }

    func readOnlyModel(_ server: FakeZCodeServer) async throws -> ConversationModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, readOnly: true)
        await model.start()
        try await emitConversation(server, initialConversationFrame {
            $0["control"] = self.control("running", canStop: true)
            $0["availability"] = self.goalAvailability()
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func niVibrationsNiReglages() async throws {
        let server = try await conversationServer()
        let model = try await readOnlyModel(server)
        #expect(model.readOnly)
        #expect(model.settings == nil)                                    // pas de composeur
        let finish = JSONValue.object(["op": .string("state.updated"), "patch": .object([
            "control": control("completedSuccess", canStop: false), "revision": .number(10),
        ])])
        await server.emit(conversationEvent, try conversationDeltas([finish, pendingPatch([try syntheticInteraction("perm_bash")], revision: 11)]))
        _ = try await eventually { model.canStop == false ? true : nil }
        #expect(model.finishedTurns == 0)
        #expect(model.newInteractionAlerts == 0)
        // L'hôte permet ces actions (le test témoin ci-dessous le montre) : coupées à la source en lecture seule.
        #expect(model.canPauseGoal == false)
        #expect(model.canResumeGoal == false)
        #expect(model.retryEntryId == nil)
        #expect(model.forkableRowIds.isEmpty)
    }

    @Test func memeEtatHorsLectureSeuleAutoriseLesActions() async throws {
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame {
            $0["availability"] = self.goalAvailability()
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(!model.readOnly)
        #expect(model.canPauseGoal && model.canResumeGoal)
        #expect(model.retryEntryId != nil)
        #expect(!model.forkableRowIds.isEmpty)
    }

    @Test func aucuneRequeteHorsAbonnement() async throws {
        let server = try await conversationServer()
        _ = try await readOnlyModel(server)
        // Ni catalogue de modèles ni catalogue de skills : seul l'abonnement part (le web a vu des runtimes fantômes).
        #expect(await server.calls(to: "zcode-agent.getSkillReferenceCatalog").isEmpty)
        #expect(await server.callNames(prefix: "model-selection.").isEmpty)
        #expect(await server.callNames(prefix: "zcode-session.").isEmpty)
    }

    @Test func sousAgentsEnCoursDuSnapshot() async throws {
        let server = try await conversationServer()
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame {
            $0["subagents"] = .object(["running": .array([
                .object(["childSessionId": .string("c1"), "subagentType": .string("Explore"), "title": .string("T"),
                         "status": .string("running")]),
            ])])
        })
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(model.runningSubagents.map(\.childSessionId) == ["c1"])
    }
}
