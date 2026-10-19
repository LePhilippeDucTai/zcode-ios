import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationFileChangesTests {
    let target = RowTarget(rowId: 1, entityId: "turn:t1")

    static func changesJSON() -> JSONValue {
        .object([
            "files": .number(1), "additions": .number(2), "deletions": .number(1), "state": .string("active"),
            "items": .array([.object([
                "path": .string("\(testWorkspacePath)/src/a.ts"), "additions": .number(2), "deletions": .number(1),
                "writeCount": .number(2), "toolNames": .array([.string("Edit")]),
                "patches": .array([.object([
                    "oldStart": .number(1), "oldLines": .number(1), "newStart": .number(1), "newLines": .number(2),
                    "lines": .array([.string("-const x = 1;"), .string("+const x = 2;"), .string("+const y = 3;")]),
                ])]),
            ])]),
        ])
    }

    func readyModel(_ server: FakeZCodeServer) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    func calls(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.conversationFileChangesV4")
    }

    @Test func fichiersDuTour() async throws {
        let server = try await conversationServer()
        let changes = Self.changesJSON()
        await server.on("zcode-agent.conversationFileChangesV4") { _ in changes }
        let model = try await readyModel(server)
        guard case .loaded(let result) = await model.fileChanges(for: target) else { Issue.record("fichiers attendus"); return }
        #expect(result.items.first?.toolNames == ["Edit"])
        let call = try #require(await calls(server).first)
        #expect(call["target"] == target.json)
        #expect(call["sessionId"] == .string(pongSession))
        let snapshot = try #require(model.snapshot)
        #expect(call["baseRevision"] == .number(Double(snapshot.revision)))
        #expect(call["baseLogEpoch"] == .string(snapshot.logEpoch))
    }

    @Test func revisionDepasseeReessayee() async throws {
        let server = try await conversationServer()
        let changes = Self.changesJSON()
        let attempts = Counter()
        await server.on("zcode-agent.conversationFileChangesV4") { _ in
            if attempts.next() == 1 { throw FakeRemoteError("proto.staleRevision") }
            return changes
        }
        let model = try await readyModel(server)
        guard case .loaded = await model.fileChanges(for: target) else { Issue.record("fichiers attendus"); return }
        #expect(await calls(server).count == 2)
    }

    @Test func revisionToujoursDepassee() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.conversationFileChangesV4") { _ in throw FakeRemoteError("proto.staleRevision") }
        let model = try await readyModel(server)
        #expect(await model.fileChanges(for: target) == .failed("La conversation a changé pendant le chargement : réessaie."))
        #expect(await calls(server).count == 3)
    }

    @Test func hoteSansDetailDesFichiers() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.conversationFileChangesV4") { _ in throw FakeRemoteError("fault.fileChanges.unsupported") }
        let model = try await readyModel(server)
        #expect(await model.fileChanges(for: target)
            == .failed("Cet hôte ne fournit pas le détail des fichiers modifiés : ouvre l'interface web."))
        #expect(await calls(server).count == 1)                           // pas de nouvel essai
    }
}
