import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Faux serveur dont `file.readdir` sert un arbre de dossiers : home = /Users/me (dérivé du
/// premier projet annoncé), avec `claude` (dossier, contient `zcode_ios`) et `Documents` (dossier vide),
/// plus un fichier `notes.txt` (masqué : pas un dossier).
func pickerServer() async throws -> FakeZCodeServer {
    let server = try await readyServer()
    func entry(_ name: String, _ path: String, _ type: String) -> JSONValue {
        .object(["name": .string(name), "path": .string(path), "type": .string(type), "isSymbolicLink": .bool(false)])
    }
    let home = "/Users/me"
    let listings: [String: JSONValue] = [
        home: .array([
            entry("claude", "\(home)/claude", "directory"),
            entry("Documents", "\(home)/Documents", "directory"),
            entry("notes.txt", "\(home)/notes.txt", "file"),
        ]),
        "\(home)/claude": .array([entry("zcode_ios", "\(home)/claude/zcode_ios", "directory")]),
        "\(home)/Documents": .array([]),
        "/": .array([entry("Users", "/Users", "directory")]),
    ]
    await server.on("file.readdir") { argument in
        let path = argument["path"]?.stringValue ?? ""
        guard let listing = listings[path] else {
            throw FakeRemoteError("ENOENT: no such file or directory, scandir '\(path)'", code: "ENOENT")
        }
        return listing
    }
    return server
}

@MainActor
struct ProjectPickerTests {
    func connection(_ server: FakeZCodeServer, workspaces: [String] = [testWorkspacePath]) -> HostConnection {
        HostConnection(host: testHost, endpoint: testEndpoint,
                       dependencies: makeDependencies(servers: ServerQueue([server]),
                                                      serverInfo: { makeServerInfo(workspaces: workspaces) }))
    }

    @Test func racineHomeEtDossiersSeuls() async throws {
        let server = try await pickerServer()
        let picker = ProjectPickerModel(connection: connection(server))
        await picker.start()
        #expect(picker.path == "/Users/me")                       // parent du premier projet annoncé
        guard case .loaded(let entries) = picker.listing else { Issue.record("liste attendue"); return }
        #expect(entries.map(\.name) == ["claude", "Documents"])           // fichier filtré, ordre de l'hôte gardé
        #expect(picker.canGoUp == false)
        #expect(await server.calls(to: "file.readdir").map { $0["path"]?.stringValue } == ["/Users/me"])
        #expect(await server.calls(to: "file.readdir").map { $0["includeHidden"] } == [.bool(false)])
    }

    @Test func navigationEtRemontee() async throws {
        let server = try await pickerServer()
        let picker = ProjectPickerModel(connection: connection(server))
        await picker.start()
        guard case .loaded(let entries) = picker.listing else { Issue.record("liste attendue"); return }
        await picker.descend(entries[0])                                  // claude
        #expect(picker.path == "/Users/me/claude" && picker.canGoUp)
        guard case .loaded(let sub) = picker.listing else { Issue.record("liste attendue"); return }
        #expect(sub.map(\.name) == ["zcode_ios"])
        await picker.descend(sub[0])                                      // zcode_ios (non servi : ENOENT)
        #expect(picker.path == "/Users/me/claude/zcode_ios")
        #expect(picker.listing == .failed("Fichier ou dossier introuvable sur l'hôte."))
        await picker.goUp()                                               // retour à claude, liste relue
        #expect(picker.path == "/Users/me/claude" && picker.canGoUp)
        guard case .loaded = picker.listing else { Issue.record("liste attendue"); return }
        await picker.goUp()                                               // retour à home
        #expect(picker.path == "/Users/me" && !picker.canGoUp)
        await picker.goUp()                                               // inactif à la racine
        #expect(picker.path == "/Users/me")
    }

    @Test func racineRepliSurSlashSansProjetAnnonce() async throws {
        let server = try await pickerServer()
        let picker = ProjectPickerModel(connection: connection(server, workspaces: []))
        await picker.start()
        #expect(picker.path == "/")
        guard case .loaded(let entries) = picker.listing else { Issue.record("liste attendue"); return }
        #expect(entries.map(\.name) == ["Users"])
    }

    @Test func racineRepliSurSlashSiHomeIllisible() async throws {
        let server = try await pickerServer()
        // Home dérivé (/Users/me) non relu : repli sur /.
        await server.on("file.readdir") { argument in
            if argument["path"]?.stringValue == "/" {
                return .array([.object(["name": .string("home"), "path": .string("/home"),
                                        "type": .string("directory"), "isSymbolicLink": .bool(false)])])
            }
            throw FakeRemoteError("EACCES: permission denied, scandir", code: "EACCES")
        }
        let picker = ProjectPickerModel(connection: connection(server))
        await picker.start()
        #expect(picker.path == "/")
        guard case .loaded(let entries) = picker.listing else { Issue.record("liste attendue"); return }
        #expect(entries.map(\.name) == ["home"])
    }

    @Test func erreurTraduiteEtReessai() async throws {
        let server = try await pickerServer()
        let picker = ProjectPickerModel(connection: connection(server), root: "/Users/me/absent")
        await picker.start()
        #expect(picker.listing == .failed("Fichier ou dossier introuvable sur l'hôte."))
        await server.on("file.readdir") { _ in
            .array([.object(["name": .string("claude"), "path": .string("/Users/me/claude"),
                             "type": .string("directory"), "isSymbolicLink": .bool(false)])])
        }
        await picker.reload()
        guard case .loaded(let entries) = picker.listing else { Issue.record("liste attendue"); return }
        #expect(entries.map(\.name) == ["claude"])
    }

    @Test func hoteInjoignable() async {
        // Token absent : échec immédiat, non retenté.
        let offline = HostConnection(host: testHost, endpoint: nil,
                                     dependencies: makeDependencies(servers: ServerQueue([])))
        let picker = ProjectPickerModel(connection: offline, root: "/x")
        await picker.start()
        guard case .failed(let message) = picker.listing else { Issue.record("échec attendu"); return }
        #expect(message.contains("Token"))
    }

    @Test func descendIgnoreUnFichier() async throws {
        let server = try await pickerServer()
        let picker = ProjectPickerModel(connection: connection(server))
        await picker.start()
        let file = try FileEntry.list(json: .array([
            .object(["name": .string("notes.txt"), "path": .string("/Users/me/notes.txt"),
                     "type": .string("file"), "isSymbolicLink": .bool(false)]),
        ]))
        await picker.descend(file[0])
        #expect(picker.path == "/Users/me")                       // inchangé
    }

    @Test func doublonIgnoreParLeStore() throws {
        // La validation reste celle de `HostStore` : un chemin déjà listé n'est pas ajouté deux fois.
        let hosts = HostStore(persistence: InMemoryHostPersistence(), tokens: InMemoryTokenStore())
        let host = try hosts.add(name: "Mac", url: "mac.ts.net", token: "t")
        try hosts.addWorkspace("/Users/me/claude", to: host.id)
        try hosts.addWorkspace("/Users/me/claude", to: host.id)
        #expect(hosts.host(id: host.id)?.manualWorkspaces == ["/Users/me/claude"])
    }
}
