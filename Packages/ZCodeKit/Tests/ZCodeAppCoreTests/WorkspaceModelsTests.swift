import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private let repo = "/private/tmp/zcode-fixture-repo"

/// Serveur qui sert les réponses réelles de `git-files` ; `getDiff` et `readTextFile` selon le chemin demandé.
func workspaceServer() async throws -> FakeZCodeServer {
    let server = try await readyServer()
    let refresh = try gitFilesRecord("001")
    let diffs: [String: JSONValue] = [
        "\(repo)/README.md": try gitFilesRecord("002"), "\(repo)/new.txt": try gitFilesRecord("003"),
        "\(repo)/logo.bin": try gitFilesRecord("004"), "\(repo)/src/app.swift": try gitFilesRecord("005"),
    ]
    let visible = try gitFilesRecord("008")
    let hidden = try gitFilesRecord("009")
    let texts: [String: JSONValue] = [
        "\(repo)/README.md": try gitFilesRecord("011"), "\(repo)/big.txt": try gitFilesRecord("012"),
        "\(repo)/logo.bin": try gitFilesRecord("013"),
    ]
    let matches = try gitFilesRecord("015")
    await server.on("git.refresh") { _ in refresh }
    await server.on("git.getDiff") { argument in
        guard let path = argument["path"]?.stringValue, let diff = diffs[path] else { throw FakeRemoteError("chemin inconnu") }
        return diff
    }
    await server.on("file.readdir") { argument in
        if argument["path"]?.stringValue == "\(repo)/absent" {
            throw FakeRemoteError("ENOENT: no such file or directory, scandir '\(repo)/absent'", code: "ENOENT")
        }
        return argument["includeHidden"]?.boolValue == true ? hidden : visible
    }
    await server.on("file.readTextFile") { argument in
        let path = argument["path"]?.stringValue ?? ""
        guard let text = texts[path] else { throw FakeRemoteError("Path is not a file: \(path)") }
        return text
    }
    await server.on("file.searchWorkspaceFiles") { _ in matches }
    return server
}

@MainActor
struct WorkspaceModelsTests {
    func connection(_ server: FakeZCodeServer) -> HostConnection {
        HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: ServerQueue([server])))
    }

    @Test func modificationsDuDepot() async throws {
        let server = try await workspaceServer()
        let changes = WorkspaceChangesModel(connection: connection(server), workspace: repo)
        await changes.refresh()
        #expect(changes.phase == .ready)
        #expect(changes.summary?.branchName == "main")
        #expect(changes.staged.map(\.workspaceRelativePath) == ["renamed.txt", "src/app.swift"])
        #expect(changes.unstaged.map(\.workspaceRelativePath) == ["README.md", "logo.bin"])
        #expect(changes.untracked.map(\.workspaceRelativePath) == ["new.txt"])
        #expect(changes.conflicted.isEmpty && !changes.isEmpty)

        guard case .loaded(let files) = await changes.diff(for: changes.unstaged[0]) else { Issue.record("diff attendu"); return }
        #expect(files.first?.path == "README.md" && files.first?.additions == 2)
        #expect(await changes.diff(for: changes.unstaged[1]) == .unavailable("Fichier binaire : pas d'aperçu du diff."))
        guard case .loaded = await changes.diff(for: changes.staged[1]) else { Issue.record("diff indexé attendu"); return }
        #expect(await server.calls(to: "git.getDiff").map { $0["sourceId"]?.stringValue } == ["unstaged", "unstaged", "staged"])
        #expect(GitChangeKind.renamed.label == "Renommé")
        #expect(GitChangeKind(rawValue: "typechange").label == "typechange")
    }

    @Test func projetHorsDepot() async throws {
        let server = try await readyServer()
        let outside = try gitFilesRecord("007")
        await server.on("git.refresh") { _ in outside }
        let changes = WorkspaceChangesModel(connection: connection(server), workspace: "/private/tmp/zcode-fixture-norepo")
        await changes.refresh()
        #expect(changes.phase == .notRepository)
        #expect(changes.summary?.isGitAvailable == true)
        #expect(changes.isEmpty)
    }

    @Test func erreurDeGit() async throws {
        let server = try await readyServer()
        await server.on("git.refresh") { _ in throw FakeRemoteError("git status timed out after 15000ms") }
        let changes = WorkspaceChangesModel(connection: connection(server), workspace: repo)
        await changes.refresh()
        #expect(changes.phase == .failed("Modifications indisponibles : git status timed out after 15000ms"))
    }

    @Test func dossiersEtFichiersCaches() async throws {
        let server = try await workspaceServer()
        let browser = FileBrowser(connection: connection(server), root: repo)
        await browser.load(repo)
        guard case .loaded(let visible) = browser.listing(repo) else { Issue.record("liste attendue"); return }
        #expect(visible.count == 6 && visible.first?.name == "src")
        await browser.setShowsHidden(true)                      // les dossiers déjà vus sont relus
        #expect(browser.showsHidden)
        guard case .loaded(let all) = browser.listing(repo) else { Issue.record("liste attendue"); return }
        #expect(all.count == 8)
        #expect(await server.calls(to: "file.readdir").map { $0["includeHidden"] } == [.bool(false), .bool(true)])
        await browser.load("\(repo)/absent")
        #expect(browser.listing("\(repo)/absent") == .failed("Fichier ou dossier introuvable sur l'hôte."))
    }

    @Test func lectureDeFichiers() async throws {
        let server = try await workspaceServer()
        let browser = FileBrowser(connection: connection(server), root: repo)
        #expect(await browser.read("\(repo)/README.md") == .text(
            lines: ["# Démo", "", "Ligne 1", "Ligne 2 modifiée", "Ligne 3", "Ligne 4"], truncated: false, totalBytes: 51))
        guard case .text(let lines, let truncated, let total) = await browser.read("\(repo)/big.txt") else {
            Issue.record("texte attendu"); return
        }
        #expect(truncated && total == 298_500)
        #expect(lines.last?.hasSuffix("é") == true)                         // caractère coupé (U+FFFD) retiré
        #expect(await browser.read("\(repo)/logo.bin") == .binary(totalBytes: 300))
        #expect(await browser.read("\(repo)/src") == .failed("Ce chemin n'est pas un fichier."))
    }

    @Test func rechercheMasqueLesFichiersCaches() async throws {
        let server = try await workspaceServer()
        let browser = FileBrowser(connection: connection(server), root: repo)
        await browser.search("  app ")
        #expect(browser.searchQuery == "app")
        #expect(browser.searchResults.first?.relativePath == "src/app.swift")
        #expect(!browser.searchResults.contains { $0.relativePath == ".hidden" })
        await browser.setShowsHidden(true)
        await browser.search("app")
        #expect(browser.searchResults.contains { $0.relativePath == ".hidden" })
        await browser.search("")
        #expect(browser.searchResults.isEmpty && browser.searchQuery.isEmpty)
        #expect(await server.calls(to: "file.searchWorkspaceFiles").map { $0["query"] } == [.string("app"), .string("app")])
    }

    @Test func ligneGeanteDUnFichierCoupee() async throws {
        let server = try await workspaceServer()
        let content = "court\n" + String(repeating: "x", count: 250_000)
        await server.on("file.readTextFile") { _ in
            .object(["path": .string("\(repo)/min.js"), "content": .string(content), "offset": .number(0),
                     "bytesRead": .number(250_006), "totalBytes": .number(250_006), "truncated": .bool(false),
                     "isBinary": .bool(false)])
        }
        let browser = FileBrowser(connection: connection(server), root: repo)
        guard case .text(let lines, _, _) = await browser.read("\(repo)/min.js") else { Issue.record("texte attendu"); return }
        #expect(lines.first == "court")
        #expect(lines.last?.count ?? .max < 2_100 && lines.last?.hasSuffix("… (250000 caractères)") == true)
    }
}
