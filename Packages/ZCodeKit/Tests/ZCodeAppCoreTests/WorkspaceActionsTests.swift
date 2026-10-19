import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private let repo = "/private/tmp/zcode-fixture-repo"

/// `git.refresh` de la fixture 001 (pas d'upstream) avec un autre résumé.
private func refreshWith(_ changes: [String: JSONValue]) throws -> JSONValue {
    guard case .object(var root) = try gitFilesRecord("001"), case .object(var summary)? = root["summary"] else {
        throw FakeRemoteError("fixture 001 illisible")
    }
    summary.merge(changes) { $1 }
    root["summary"] = .object(summary)
    return .object(root)
}

/// Serveur des modèles (tâche 4) + mutations réelles de `git-actions`.
private func actionsServer() async throws -> FakeZCodeServer {
    let server = try await workspaceServer()
    for method in ["stagePaths", "unstagePaths", "discardPaths"] { await server.on("git.\(method)") { _ in .null } }
    let commit = try gitActionsRecord("009"), push = try gitActionsRecord("013"), generated = try gitActionsRecord("016")
    let branches = try gitActionsRecord("012")
    await server.on("git.commit") { _ in commit }
    await server.on("git.push") { _ in push }
    await server.on("git.generateCommitMessage") { _ in generated }
    await server.on("git.getLocalBranches") { _ in branches }
    return server
}

@MainActor
struct WorkspaceActionsTests {
    func ready(_ server: FakeZCodeServer) async -> WorkspaceChangesModel {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: ServerQueue([server])))
        let changes = WorkspaceChangesModel(connection: connection, workspace: repo)
        await changes.refresh()
        return changes
    }

    @Test func indexerEtDesindexerRelisentLEtat() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        await changes.stage([changes.unstaged[0]])
        #expect(await server.calls(to: "git.stagePaths") == [.object([
            "workspacePath": .string(repo), "paths": .array([.string("\(repo)/README.md")]),
        ])])
        await changes.unstage([changes.staged[1]])
        #expect(await server.calls(to: "git.unstagePaths").first?["paths"] == .array([.string("\(repo)/src/app.swift")]))
        #expect(await server.calls(to: "git.refresh").count == 3)
        #expect(changes.action == nil && changes.actionError == nil)
    }

    @Test func annulationRefuseeSurNonSuivi() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        #expect(!changes.canDiscard(changes.untracked[0]))
        #expect(changes.canDiscard(changes.unstaged[0]) && changes.canDiscard(changes.staged[1]))
        #expect(changes.staged[0].kind == .renamed && !changes.canDiscard(changes.staged[0]))   // fichier perdu sinon
        await changes.discard(changes.staged[0])
        await changes.discard(changes.staged[1])
        await changes.discard(changes.unstaged[0])
        #expect(await server.calls(to: "git.discardPaths").map { $0["staged"] } == [.bool(true), .bool(false)])
        await changes.discard(changes.untracked[0])
        #expect(await server.calls(to: "git.discardPaths").count == 2)
    }

    /// `git restore --source=HEAD --staged --worktree` sur un fichier ajouté l'efface du disque : pas d'annulation.
    @Test func annulationRefuseeSurAjoutIndexe() async throws {
        let server = try await actionsServer()
        guard case .object(var root) = try gitFilesRecord("001"), case .array(var staged)? = root["stagedChanges"],
              case .object(var change) = staged[1] else { Issue.record("fixture 001 illisible"); return }
        change["kind"] = .string("added")
        staged[1] = .object(change)
        root["stagedChanges"] = .array(staged)
        let refresh = JSONValue.object(root)
        await server.on("git.refresh") { _ in refresh }
        let changes = await ready(server)
        #expect(changes.staged[1].kind == .added && !changes.canDiscard(changes.staged[1]))
        await changes.discard(changes.staged[1])
        #expect(await server.calls(to: "git.discardPaths").isEmpty)
    }

    @Test func messageVideGenereAvantDeValider() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        #expect(await changes.commit(message: "  ", includeUnstaged: false, push: false))
        #expect(await server.callNames(prefix: "git.").filter { $0 != "git.refresh" } == ["git.generateCommitMessage", "git.commit"])
        #expect(await server.calls(to: "git.generateCommitMessage") == [.object([
            "workspacePath": .string(repo), "locale": .string("en-US"), "includeUnstaged": .bool(false),
        ])])
        #expect(await server.calls(to: "git.commit") == [.object([
            "workspacePath": .string(repo), "message": .string("chore: add new.txt with sample line"),
            "paths": .array([.string("\(repo)/renamed.txt"), .string("\(repo)/src/app.swift")]), "stagedOnly": .bool(true),
        ])])
        #expect(changes.notice == "Validé (9c48005)")
    }

    @Test func inclureLesNonIndexesIndexeDAbord() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        #expect(await changes.commit(message: "feat: x", includeUnstaged: true, push: false))
        #expect(await server.callNames(prefix: "git.").filter { $0 != "git.refresh" } == ["git.stagePaths", "git.commit"])
        let extra: [JSONValue] = [.string("\(repo)/README.md"), .string("\(repo)/logo.bin"), .string("\(repo)/new.txt")]
        #expect(await server.calls(to: "git.stagePaths").first?["paths"] == .array(extra))
        let commit = try #require(await server.calls(to: "git.commit").first)
        #expect(commit["stagedOnly"] == .bool(false) && commit["message"] == .string("feat: x"))
        #expect(commit["paths"] == .array([]))                    // `git commit -- chemins` casserait le renommage indexé
    }

    @Test func rienAValider() async throws {
        let server = try await actionsServer()
        let onlyUntracked = try gitActionsRecord("011")
        await server.on("git.refresh") { _ in onlyUntracked }
        let changes = await ready(server)
        #expect(await !changes.commit(message: "feat: x", includeUnstaged: false, push: false))
        #expect(await server.calls(to: "git.commit").isEmpty)
        #expect(changes.actionError == "Rien à valider : indexe des fichiers ou inclus les modifications non indexées.")
    }

    @Test func valideMaisPushEchoue() async throws {
        let server = try await actionsServer()
        await server.on("git.push") { _ in
            throw FakeRemoteError("git push failed: fatal: could not read Username for 'https://github.com': Device not configured")
        }
        let changes = await ready(server)
        #expect(await changes.commit(message: "feat: x", includeUnstaged: false, push: true))
        #expect(changes.actionError == "Validé, mais le push a échoué : Le push demande des identifiants que l'hôte n'a pas : configure SSH ou le trousseau sur l'hôte.")
        #expect(await server.calls(to: "git.commit").count == 1)
    }

    @Test func pousserSelonAvanceEtUpstream() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        #expect(changes.canPush)                                                   // pas d'upstream : publier
        #expect(await changes.push())
        #expect(changes.notice == "Poussé vers origin/main")

        let upToDate = try refreshWith(["trackingBranchName": .string("origin/main"), "ahead": .number(0)])
        await server.on("git.refresh") { _ in upToDate }
        await changes.refresh()
        #expect(!changes.canPush)
        let ahead = try refreshWith(["trackingBranchName": .string("origin/main"), "ahead": .number(2)])
        await server.on("git.refresh") { _ in ahead }
        await changes.refresh()
        #expect(changes.canPush)
        let detached = try refreshWith(["headRefType": .string("detached"), "branchName": .null])
        await server.on("git.refresh") { _ in detached }
        await changes.refresh()
        #expect(!changes.canPush)
    }

    @Test func changementBloqueProposeDeValider() async throws {
        let server = try await actionsServer()
        let blocked = try gitActionsRecord("006"), switched = try gitActionsRecord("015")
        let attempts = Counter()
        await server.on("git.switchBranch") { _ in attempts.next() == 1 ? blocked : switched }
        let changes = await ready(server)
        #expect(await changes.switchBranch(to: "autre") == .needsCommit(branch: "autre", paths: ["README.md"]))
        #expect(await changes.commitAndSwitch(to: "autre", message: "") == .switched("feature/fixture"))
        #expect(await server.callNames(prefix: "git.").filter { $0 != "git.refresh" && $0 != "git.getLocalBranches" }
            == ["git.switchBranch", "git.stagePaths", "git.commit", "git.switchBranch"])
        #expect(await server.calls(to: "git.commit") == [.object([
            "workspacePath": .string(repo), "message": .string("chore: checkpoint before switching to autre"),
            "paths": .array([]), "stagedOnly": .bool(false),
        ])])
        #expect(await server.calls(to: "git.stagePaths").first?["paths"]
            == .array([.string("\(repo)/README.md"), .string("\(repo)/logo.bin"), .string("\(repo)/new.txt")]))
    }

    @Test func issueDeBrancheTraduite() async throws {
        let server = try await actionsServer()
        let invalid = try gitActionsRecord("008"), missing = try gitActionsRecord("007")
        await server.on("git.createBranchAndSwitch") { _ in invalid }
        await server.on("git.switchBranch") { _ in missing }
        let changes = await ready(server)
        #expect(await changes.createBranch("bad..name") == .failed("Nom de branche invalide : choisis-en un autre."))
        #expect(await changes.switchBranch(to: "absente") == .failed("Cette branche n'existe pas localement."))
        #expect(changes.actionError == "Cette branche n'existe pas localement.")       // affiché dans l'écran
        await changes.loadBranches()
        #expect(changes.branches.map(\.name) == ["main", "autre"])
    }

    @Test func erreursDeGitTraduites() async throws {
        let server = try await actionsServer()
        await server.on("git.commit") { _ in
            throw FakeRemoteError("git commit failed: Author identity unknown\n\n*** Please tell me who you are.")
        }
        await server.on("git.generateCommitMessage") { _ in throw FakeRemoteError("There are no changes available to commit.") }
        let changes = await ready(server)
        #expect(await !changes.commit(message: "feat: x", includeUnstaged: false, push: false))
        #expect(changes.actionError == "Identité Git absente sur l'hôte : configure user.name et user.email.")
        #expect(await !changes.commit(message: "", includeUnstaged: false, push: false))
        #expect(changes.actionError == "Génération du message impossible : réessaie ou écris-le.")
        #expect(await server.calls(to: "git.commit").count == 1)
        changes.dismissActionMessages()
        #expect(changes.actionError == nil && changes.notice == nil)
    }

    @Test func uneActionALaFois() async throws {
        let server = try await actionsServer()
        let changes = await ready(server)
        async let first: Void = changes.stage([changes.unstaged[0]])
        async let second: Void = changes.stage([changes.unstaged[1]])
        _ = await (first, second)
        #expect(await server.calls(to: "git.stagePaths").count == 1)
    }
}
