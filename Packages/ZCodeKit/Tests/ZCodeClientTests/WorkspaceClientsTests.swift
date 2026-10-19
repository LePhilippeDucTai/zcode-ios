import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private let repo = "/private/tmp/zcode-fixture-repo"

private func record(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-files").first { $0.file.hasPrefix(prefix) }).value
}

private func record(actions prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-actions").first { $0.file.hasPrefix(prefix) }).value
}

struct WorkspaceClientsTests {
    func connected(_ server: FakeZCodeServer) async -> ChannelClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return client
    }

    @Test func etatEtDiffGit() async throws {
        let server = FakeZCodeServer()
        let refresh = try record("001")
        let diff = try record("005")
        await server.on("git.refresh") { _ in refresh }
        await server.on("git.getDiff") { _ in diff }
        let git = GitClient(client: await connected(server), workspacePath: repo)
        #expect(try await git.refresh().stagedChanges.count == 2)
        #expect(try await git.diff(path: "\(repo)/src/app.swift", source: .staged).availability == .patch)
        #expect(await server.calls(to: "git.refresh") == [.object([
            "workspacePath": .string(repo), "includeIdentity": .bool(false), "includeBranchComparison": .bool(false),
        ])])
        #expect(await server.calls(to: "git.getDiff") == [.object([
            "workspacePath": .string(repo), "path": .string("\(repo)/src/app.swift"), "sourceId": .string("staged"),
        ])])
    }

    @Test func dossiersLecturesEtRecherche() async throws {
        let server = FakeZCodeServer()
        let listing = try record("009")
        let text = try record("011")
        let matches = try record("015")
        await server.on("file.readdir") { _ in listing }
        await server.on("file.readTextFile") { _ in text }
        await server.on("file.searchWorkspaceFiles") { _ in matches }
        let files = FileClient(client: await connected(server))
        #expect(try await files.readdir(path: repo, includeHidden: true).count == 8)
        #expect(try await files.readTextFile(path: "\(repo)/README.md").totalBytes == 51)
        #expect(try await files.search(root: repo, query: "app").first?.name == "app.swift")
        #expect(await server.calls(to: "file.readdir") == [.object(["path": .string(repo), "includeHidden": .bool(true)])])
        #expect(await server.calls(to: "file.readTextFile") == [.object([
            "path": .string("\(repo)/README.md"), "length": .number(262_144),
        ])])
        #expect(await server.calls(to: "file.searchWorkspaceFiles") == [.object([
            "rootPath": .string(repo), "query": .string("app"), "limit": .number(200),
        ])])
    }

    @Test func erreurDeLHoteAvecSonCode() async throws {
        let server = FakeZCodeServer()
        await server.on("file.readdir") { _ in
            throw FakeRemoteError("ENOENT: no such file or directory, scandir '/x'", code: "ENOENT")
        }
        let files = FileClient(client: await connected(server))
        do {
            _ = try await files.readdir(path: "/x", includeHidden: false)
            Issue.record("erreur attendue")
        } catch RPCError.remote(let remote) {
            #expect(remote.code == .string("ENOENT"))
            #expect(remote.message.hasPrefix("ENOENT"))
        }
    }

    @Test func reponsesIllisibles() async throws {
        let server = FakeZCodeServer()
        await server.on("file.readdir") { _ in .object([:]) }
        await server.on("git.refresh") { _ in .string("?") }
        let client = await connected(server)
        await #expect(throws: AgentV4Error.self) { try await FileClient(client: client).readdir(path: "/x", includeHidden: false) }
        await #expect(throws: AgentV4Error.self) { try await GitClient(client: client, workspacePath: "/x").refresh() }
    }

    @Test func actionsGitEnvoientLesBonsArguments() async throws {
        let server = FakeZCodeServer()
        for method in ["stagePaths", "unstagePaths", "discardPaths"] { await server.on("git.\(method)") { _ in .null } }
        let commit = try record(actions: "009"), push = try record(actions: "013"), created = try record(actions: "015")
        let branches = try record(actions: "012"), blocked = try record(actions: "006"), generated = try record(actions: "016")
        await server.on("git.commit") { _ in commit }
        await server.on("git.push") { _ in push }
        await server.on("git.createBranchAndSwitch") { _ in created }
        await server.on("git.switchBranch") { _ in blocked }
        await server.on("git.getLocalBranches") { _ in branches }
        await server.on("git.generateCommitMessage") { _ in generated }
        let git = GitClient(client: await connected(server), workspacePath: repo)
        try await git.stage(paths: ["\(repo)/a"])
        try await git.unstage(paths: ["\(repo)/a"])
        try await git.discard(paths: ["\(repo)/a"], staged: true)
        #expect(try await git.commit(message: "m", paths: ["\(repo)/a"], stagedOnly: true).commitHash.count == 40)
        #expect(try await git.push().setUpstream)
        #expect(try await git.createBranch("feature/x").created)
        #expect(try await !git.switchBranch(to: "autre").ok)
        #expect(try await git.localBranches().branches.count == 2)
        #expect(try await !git.generateCommitMessage(includeUnstaged: false).message.isEmpty)
        let paths: JSONValue = .array([.string("\(repo)/a")])
        #expect(await server.calls(to: "git.stagePaths") == [.object(["workspacePath": .string(repo), "paths": paths])])
        #expect(await server.calls(to: "git.unstagePaths") == [.object(["workspacePath": .string(repo), "paths": paths])])
        #expect(await server.calls(to: "git.discardPaths") == [.object([
            "workspacePath": .string(repo), "paths": paths, "staged": .bool(true),
        ])])
        #expect(await server.calls(to: "git.commit") == [.object([
            "workspacePath": .string(repo), "message": .string("m"), "paths": paths, "stagedOnly": .bool(true),
        ])])
        #expect(await server.calls(to: "git.push") == [.object(["workspacePath": .string(repo)])])
        #expect(await server.calls(to: "git.createBranchAndSwitch") == [.object([
            "workspacePath": .string(repo), "branchName": .string("feature/x"),
        ])])
        #expect(await server.calls(to: "git.switchBranch") == [.object([
            "workspacePath": .string(repo), "targetBranchName": .string("autre"),
        ])])
        #expect(await server.calls(to: "git.getLocalBranches") == [.object(["workspacePath": .string(repo)])])
        #expect(await server.calls(to: "git.generateCommitMessage") == [.object([
            "workspacePath": .string(repo), "locale": .string("en-US"), "includeUnstaged": .bool(false),
        ])])
    }

    @Test func actionsGitReponsesIllisibles() async throws {
        let server = FakeZCodeServer()
        await server.on("git.commit") { _ in .string("?") }
        await server.on("git.push") { _ in .null }
        let git = GitClient(client: await connected(server), workspacePath: repo)
        await #expect(throws: AgentV4Error.self) { try await git.commit(message: "m", paths: [], stagedOnly: false) }
        await #expect(throws: AgentV4Error.self) { try await git.push() }
    }
}
