import CryptoKit
import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Hôte simulé des pièces jointes : garde les morceaux reçus, rend `ref` au commit.
struct AttachmentUploadTests {
    func connectedAgent(_ server: FakeZCodeServer) async -> AgentV4 {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return AgentV4(client: client, workspacePath: "/Users/me/claude")
    }

    func stagingServer(startingAt next: Int = 0) async -> FakeZCodeServer {
        let server = FakeZCodeServer()
        await server.on("zcode-agent.attachmentBeginV4") { argument in
            .object(["uploadId": argument["uploadId"] ?? .null, "state": .string("staging"), "nextChunkIndex": .number(Double(next))])
        }
        await server.on("zcode-agent.attachmentChunkV4") { argument in
            let index = V4JSON.integer(argument["chunkIndex"]) ?? -1
            return .object(["uploadId": argument["uploadId"] ?? .null, "nextChunkIndex": .number(Double(index + 1))])
        }
        await server.on("zcode-agent.attachmentCommitV4") { _ in .object(["ref": .string("zcode-artifact://ok")]) }
        await server.on("zcode-agent.attachmentAbortV4") { _ in .object([:]) }
        return server
    }

    @Test func troisMorceauxPuisCommit() async throws {
        let server = await stagingServer()
        let agent = await connectedAgent(server)
        let data = Data((0..<(AgentV4.attachmentChunkBytes * 2 + 10)).map { UInt8($0 % 251) })
        let ref = try await agent.uploadAttachment(sessionId: "s1", fileName: "a.bin", mime: "application/octet-stream",
                                                   data: data, uploadId: "upload-t1")
        #expect(ref == AttachmentRef(ref: "zcode-artifact://ok", fileName: "a.bin", mime: "application/octet-stream",
                                     bytes: data.count))
        let begin = try #require(await server.calls(to: "zcode-agent.attachmentBeginV4").first)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(begin == .object([
            "workspacePath": .string("/Users/me/claude"), "sessionId": .string("s1"), "uploadId": .string("upload-t1"),
            "fileName": .string("a.bin"), "mime": .string("application/octet-stream"),
            "totalBytes": .number(Double(data.count)), "totalChunks": .number(3), "checksum": .string("sha256:" + hex),
        ]))
        let chunks = await server.calls(to: "zcode-agent.attachmentChunkV4")
        #expect(chunks.map { V4JSON.integer($0["chunkIndex"]) } == [0, 1, 2])
        let rebuilt = chunks.compactMap { $0["dataBase64"]?.stringValue.flatMap { Data(base64Encoded: $0) } }
            .reduce(Data(), +)
        #expect(rebuilt == data)
        #expect(await server.calls(to: "zcode-agent.attachmentCommitV4").count == 1)
        #expect(await server.calls(to: "zcode-agent.attachmentAbortV4").isEmpty)
    }

    @Test func repriseOuDejaCommite() async throws {
        let server = await stagingServer(startingAt: 1)
        let agent = await connectedAgent(server)
        let data = Data(repeating: 7, count: AgentV4.attachmentChunkBytes + 1)
        _ = try await agent.uploadAttachment(sessionId: "s1", fileName: "a", mime: "image/png", data: data)
        #expect(await server.calls(to: "zcode-agent.attachmentChunkV4").map { V4JSON.integer($0["chunkIndex"]) } == [1])

        let done = FakeZCodeServer()
        await done.on("zcode-agent.attachmentBeginV4") { argument in
            .object(["uploadId": argument["uploadId"] ?? .null, "state": .string("committed"),
                     "nextChunkIndex": .number(1), "ref": .string("zcode-artifact://deja")])
        }
        let ref = try await connectedAgent(done).uploadAttachment(sessionId: "s1", fileName: "a", mime: "image/png",
                                                                  data: Data([1]))
        #expect(ref.ref == "zcode-artifact://deja")
        #expect(await done.calls(to: "zcode-agent.attachmentChunkV4").isEmpty)
    }

    @Test func fichierVide() async throws {
        let server = await stagingServer()
        let agent = await connectedAgent(server)
        _ = try await agent.uploadAttachment(sessionId: "s1", fileName: "vide.txt", mime: "text/plain", data: Data())
        #expect(await server.calls(to: "zcode-agent.attachmentBeginV4").first?["totalChunks"] == .number(0))
        #expect(await server.calls(to: "zcode-agent.attachmentChunkV4").isEmpty)
    }

    @Test func echecDUnMorceauAbandonneLeTeleversement() async throws {
        let server = await stagingServer()
        await server.on("zcode-agent.attachmentChunkV4") { _ in throw FakeRemoteError("fault.attachment.chunkConflict") }
        let agent = await connectedAgent(server)
        await #expect(throws: (any Error).self) {
            try await agent.uploadAttachment(sessionId: "s1", fileName: "a", mime: "image/png", data: Data([1, 2, 3]))
        }
        #expect(await server.calls(to: "zcode-agent.attachmentAbortV4").count == 1)
        #expect(await server.calls(to: "zcode-agent.attachmentCommitV4").isEmpty)
    }

    /// Tâche à annuler depuis le gestionnaire du serveur simulé (qui s'exécute hors de la tâche de l'envoi).
    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<AttachmentRef, any Error>?
        func set(_ task: Task<AttachmentRef, any Error>) { lock.withLock { self.task = task } }
        /// Attend (un instant) que la tâche soit connue, puis l'annule.
        func cancel() {
            for _ in 0..<200 {
                if let task = lock.withLock({ task }) { task.cancel(); return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    @Test func annulationEnCoursAbandonneLeTeleversement() async throws {
        let server = await stagingServer()
        let box = TaskBox()
        await server.on("zcode-agent.attachmentChunkV4") { argument in
            let index = V4JSON.integer(argument["chunkIndex"]) ?? -1
            if index == 0 { box.cancel() }
            return .object(["uploadId": argument["uploadId"] ?? .null, "nextChunkIndex": .number(Double(index + 1))])
        }
        let agent = await connectedAgent(server)
        let data = Data(repeating: 3, count: AgentV4.attachmentChunkBytes * 3)
        let upload = Task {
            try await agent.uploadAttachment(sessionId: "s1", fileName: "a", mime: "image/png", data: data)
        }
        box.set(upload)
        await #expect(throws: (any Error).self) { try await upload.value }
        #expect(await server.calls(to: "zcode-agent.attachmentAbortV4").count == 1)
        #expect(await server.calls(to: "zcode-agent.attachmentCommitV4").isEmpty)
    }

    @Test func progressionIncoherente() async throws {
        let server = await stagingServer(startingAt: 5)
        let agent = await connectedAgent(server)
        await #expect(throws: AgentV4Error.self) {
            try await agent.uploadAttachment(sessionId: "s1", fileName: "a", mime: "image/png", data: Data([1]))
        }
        #expect(await server.calls(to: "zcode-agent.attachmentAbortV4").count == 1)
    }

    @Test func lecturePaginee() async throws {
        let server = FakeZCodeServer()
        let whole = Data((0..<1000).map { UInt8($0 % 256) })
        await server.on("zcode-agent.attachmentReadV4") { argument in
            let offset = V4JSON.integer(argument["offset"]) ?? 0
            let end = min(offset + 600, whole.count)
            return .object([
                "dataBase64": .string(whole.subdata(in: offset..<end).base64EncodedString()),
                "mediaType": .string("image/png"), "totalBytes": .number(1000),
                "nextOffset": end < whole.count ? .number(Double(end)) : .null,
            ])
        }
        let agent = await connectedAgent(server)
        #expect(try await agent.readAttachment(sessionId: "s1", ref: "zcode-artifact://a") == whole)
        let calls = await server.calls(to: "zcode-agent.attachmentReadV4")
        #expect(calls.map { V4JSON.integer($0["offset"]) } == [0, 600])
        #expect(calls.first?["limit"] == .number(Double(AgentV4.attachmentReadLimit)))
        await #expect(throws: AgentV4Error.self) {
            try await agent.readAttachment(sessionId: "s1", ref: "zcode-artifact://a", maxBytes: 500)
        }
    }
}
