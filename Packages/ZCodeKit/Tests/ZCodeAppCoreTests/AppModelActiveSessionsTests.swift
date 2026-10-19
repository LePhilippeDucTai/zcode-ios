import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct AppModelActiveSessionsTests {
    let otherWorkspace = "/Users/me/autre"
    let subscribe = "zcode-agent.subscribeSessionsIndexV4"

    func makeApp(_ servers: ServerQueue, workspaces: [String] = [testWorkspacePath],
                 cache: ConversationCache = ConversationCache(),
                 serverInfoDelay: Duration = .zero) throws -> (AppModel, ZCodeAppCore.Host) {
        let store = HostStore(persistence: InMemoryHostPersistence(), tokens: InMemoryTokenStore())
        let host = try store.add(name: "Mac", url: "mac.ts.net", token: "jeton")
        let dependencies = makeDependencies(servers: servers, serverInfoDelay: serverInfoDelay,
                                            serverInfo: { makeServerInfo(workspaces: workspaces) })
        return (AppModel(hostStore: store, dependencies: dependencies, offlineCache: cache), host)
    }

    /// Lignes affichées, `nil` tant que l'état n'est pas `.entries`.
    func shown(_ app: AppModel, _ host: ZCodeAppCore.Host) -> [ActiveSession]? {
        if case .entries(let shown, _) = app.activeSessions(for: host) { return shown }
        return nil
    }

    /// Copie hors ligne de l'index de `testWorkspacePath` (une session en cours) dans le cache de l'app.
    func seedBusyCopy(_ app: AppModel, _ host: ZCodeAppCore.Host) async throws {
        let frame = try snapshotFrame(testWorkspacePath, [summaryJSON("sess_copie", phase: "running")])
        let index = try SessionsIndex(json: #require(frame["frame"]?["payload"]?["snapshot"]))
        await app.offlineCache.saveSessions(index, hidden: [], hostId: host.id, workspace: testWorkspacePath,
                                            savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func pasEncoreConnectéChercheEncore() async throws {
        let (app, host) = try makeApp(ServerQueue([]), serverInfoDelay: .milliseconds(300))
        let connection = app.connection(for: host)
        #expect(app.activeSessions(for: host) == .loading)          // non connecté : aucun projet connu, rien n'est prêt
        let connecting = Task { await connection.connect() }
        _ = try await eventually { connection.state == .connecting ? true : nil }
        #expect(connection.workspaces.isEmpty)                       // `server-info` pas encore lu
        #expect(app.activeSessions(for: host) == .loading)
        await connecting.value
    }

    @Test func connectéSansProjetRienNEstCherché() async throws {
        let (app, host) = try makeApp(ServerQueue([try await readyServer()]), workspaces: [])
        await app.connection(for: host).connect()
        #expect(app.connection(for: host).state == .connected)
        #expect(app.activeSessions(for: host) == .empty)
    }

    /// Lancement à froid : la copie hors ligne s'affiche le temps du premier abonnement, sans compter ni finir la recherche.
    @Test func copieEnAttenteDeLÉtatVivantChercheEncore() async throws {
        let server = try await sessionsServer()
        await server.onDeferred(subscribe)
        let (app, host) = try makeApp(ServerQueue([server]))
        try await seedBusyCopy(app, host)
        await app.connection(for: host).connect()
        let watching = Task { await app.watchActiveSessions(for: host) }
        _ = try await eventually { await server.calls(to: subscribe).count == 1 ? true : nil }
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        #expect(sessions.isLocked && sessions.phase == .loading)
        #expect(app.activeSessions(for: host) == .loading)       // la copie (figée) ne compte pas, la recherche continue
        let ack = try Fixtures.recorded("v3.15.1/handshake-sessions/003-result-zcode-agent.subscribeSessionsIndexV4.json")
        await server.respondDeferred(subscribe, ack)
        await watching.value
        await server.emit(indexEvent, try snapshotFrame(testWorkspacePath, [summaryJSON("sess_vivante", phase: "running")]))
        let shown = try await eventually { self.shown(app, host) }
        #expect(shown.map(\.id) == ["sess_vivante"])
    }

    /// Hôte injoignable : la copie hors ligne s'affiche dans la liste du projet mais ne compte pas sur la fiche.
    @Test func copieHorsLigneIgnorée() async throws {
        let (app, host) = try makeApp(ServerQueue([]))
        try await seedBusyCopy(app, host)
        await app.connection(for: host).connect()
        await app.watchActiveSessions(for: host)
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        #expect(sessions.isLocked)
        #expect(sessions.visibleSessions.map(\.sessionId) == ["sess_copie"])
        #expect(app.activeSessions(for: host) == .empty)
    }

    /// Un projet dont l'abonnement est refusé est ignoré : il ne bloque ni n'invente rien.
    @Test func listeEnÉchecIgnorée() async throws {
        let server = try await readyServer()
        let ack = try Fixtures.recorded("v3.15.1/handshake-sessions/003-result-zcode-agent.subscribeSessionsIndexV4.json")
        await server.on(subscribe) { argument in
            if argument["workspacePath"]?.stringValue == testWorkspacePath { throw FakeRemoteError("refusé") }
            return ack
        }
        await server.on("zcode-agent.unsubscribeSessionsIndexV4") { _ in .null }
        let other = otherWorkspace
        let (app, host) = try makeApp(ServerQueue([server]), workspaces: [testWorkspacePath, other])
        await app.connection(for: host).connect()
        await app.watchActiveSessions(for: host)
        guard case .failed = app.sessions(for: host, workspace: testWorkspacePath).phase else {
            Issue.record("échec attendu"); return
        }
        #expect(app.activeSessions(for: host) == .loading)          // l'autre projet n'est pas encore lu
        try await emitWhenListening(server, snapshotFrame(other, [summaryJSON("sess_finie", phase: "completedSuccess")]))
        _ = try await eventually { app.activeSessions(for: host) == .empty ? true : nil }
        await server.emit(indexEvent, try retopic(indexDelta(upserting: summaryJSON("sess_autre", phase: "running")), other))
        let shown = try await eventually { self.shown(app, host) }
        #expect(shown.map(\.id) == ["sess_autre"])
        #expect(shown.map(\.workspace) == [other])
    }

    /// Deux projets sur un même hôte : attentes d'abord, archivée exclue, terminée exclue ; tirer pour actualiser relit
    /// chaque liste sans repasser par « Recherche… ».
    @Test func plusieursProjetsArchivéeExclueEtRelecture() async throws {
        let server = try await sessionsServer()
        let archived = JSONValue.object([
            "taskId": .string("sess_archivee"), "title": .string("Archivée"), "workspacePath": .string(testWorkspacePath),
            "traceId": .string("trace_1"), "createdAt": .number(1_791_880_000_000),
            "updatedAt": .number(1_791_890_000_000), "mode": .string("chat"),
        ])
        await server.on("zcode-task.listArchivedTasks") { argument in
            argument["workspacePath"]?.stringValue == testWorkspacePath ? .array([archived]) : .array([])
        }
        await server.on("zcode-task.listDeletedTaskIds") { _ in .array([]) }
        let other = otherWorkspace
        let (app, host) = try makeApp(ServerQueue([server]), workspaces: [testWorkspacePath, other])
        await app.connection(for: host).connect()
        await app.watchActiveSessions(for: host)
        _ = try await eventually { await server.listenerCount(indexEvent) == 2 ? true : nil }
        await server.emit(indexEvent, try snapshotFrame(testWorkspacePath, [
            summaryJSON("sess_en_cours", phase: "running", lastActivityAt: 1_791_890_000_300),
            summaryJSON("sess_archivee", phase: "running", lastActivityAt: 1_791_890_000_400),
            summaryJSON("sess_finie", phase: "completedSuccess", lastActivityAt: 1_791_890_000_500),
        ]))
        await server.emit(indexEvent, try snapshotFrame(other, [
            summaryJSON("sess_attente", phase: "completedSuccess", lastActivityAt: 1_791_890_000_100, pendingPermissions: 1),
        ]))
        let shown = try await eventually { () -> [ActiveSession]? in
            guard let shown = self.shown(app, host), shown.count == 2 else { return nil }
            return shown
        }
        #expect(shown.map(\.id) == ["sess_attente", "sess_en_cours"])
        #expect(shown.map(\.workspace) == [other, testWorkspacePath])
        #expect(shown.first?.waiting == true)

        await app.refreshActiveSessions(for: host)
        #expect(await server.calls(to: subscribe).count == 4)        // une relecture par projet
        #expect(self.shown(app, host)?.count == 2)                    // listes gardées pendant la relecture
        _ = try await eventually { await server.listenerCount(indexEvent) == 2 ? true : nil }
        await server.emit(indexEvent, try snapshotFrame(testWorkspacePath, [
            summaryJSON("sess_en_cours", phase: "completedSuccess", lastActivityAt: 1_791_890_000_600),
        ]))
        _ = try await eventually { self.shown(app, host)?.map(\.id) == ["sess_attente"] ? true : nil }
    }

    /// Hôte perdu puis retrouvé (« Réessayer » ou reconnexion automatique) : la clé de la tâche de la fiche change, la
    /// vue relance `watchActiveSessions`, qui redémarre les listes en échec.
    @Test func reconnexionRelanceLesListes() async throws {
        let first = try await sessionsServer()
        let queue = ServerQueue([first])
        let (app, host) = try makeApp(queue)
        let connection = app.connection(for: host)
        await connection.connect()
        let connectedKey = app.activeSessionsWatchKey(for: host)
        await app.watchActiveSessions(for: host)
        try await emitWhenListening(first, snapshotFrame(testWorkspacePath, [summaryJSON("sess_en_cours", phase: "running")]))
        _ = try await eventually { self.shown(app, host) }
        first.transport.finish()                     // coupure, aucun serveur ensuite : reprises épuisées
        _ = try await eventually { connection.failure != nil ? true : nil }
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        _ = try await eventually { sessions.isLocked ? true : nil }
        guard case .failed = sessions.phase else { Issue.record("liste en échec attendue"); return }
        #expect(app.activeSessions(for: host) == .empty)
        #expect(app.activeSessionsWatchKey(for: host) != connectedKey)

        let second = try await sessionsServer()
        queue.append(second)
        await connection.connect()                   // « Réessayer »
        #expect(connection.state == .connected)
        #expect(app.activeSessionsWatchKey(for: host) == connectedKey)   // nouvelle clé : la vue relance la tâche
        await app.watchActiveSessions(for: host)
        try await emitWhenListening(second, snapshotFrame(testWorkspacePath, [summaryJSON("sess_en_cours", phase: "running")]))
        let shown = try await eventually { self.shown(app, host) }
        #expect(shown.map(\.id) == ["sess_en_cours"])
        #expect(!sessions.isLocked)
        #expect(await second.calls(to: subscribe).count == 1)
    }

    @Test func sessionQuiPasseEnCoursPuisFinit() async throws {
        let server = try await sessionsServer()
        let (app, host) = try makeApp(ServerQueue([server]))
        await app.connection(for: host).connect()
        #expect(app.connection(for: host).workspaces == [testWorkspacePath])
        #expect(app.activeSessions(for: host) == .loading)          // liste créée, pas encore lue
        await app.watchActiveSessions(for: host)
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { app.activeSessions(for: host) == .empty ? true : nil }   // PONG terminée
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON("sess_en_cours", phase: "running")))
        let shown = try await eventually { () -> [ActiveSession]? in
            if case .entries(let shown, _) = app.activeSessions(for: host) { return shown }
            return nil
        }
        #expect(shown.map(\.id) == ["sess_en_cours"])
        #expect(shown.first?.workspace == testWorkspacePath)
        await server.emit(indexEvent, try indexDelta([.object(["op": .string("session.upserted"),
                                                              "session": summaryJSON("sess_en_cours", phase: "completedSuccess")])],
                                                     fromSeq: 2))
        _ = try await eventually { app.activeSessions(for: host) == .empty ? true : nil }
        // Même modèle que la liste du projet : rien de neuf côté hôte.
        #expect(await server.calls(to: "zcode-agent.subscribeSessionsIndexV4").count == 1)
    }
}
