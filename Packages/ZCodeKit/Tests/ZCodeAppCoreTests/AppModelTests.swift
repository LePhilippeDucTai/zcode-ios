import Foundation
import Observation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeWire

@MainActor
struct AppModelTests {
    func makeApp(_ servers: ServerQueue, serverInfo: @escaping @Sendable () throws -> ServerInfo = { makeServerInfo() },
                 seenStore: SeenStore = SeenStore(), now: @escaping @Sendable () -> Date = Date.init) throws -> (AppModel, ZCodeAppCore.Host) {
        let store = HostStore(persistence: InMemoryHostPersistence(), tokens: InMemoryTokenStore())
        let host = try store.add(name: "Mac", url: "mac.ts.net", token: "jeton")
        return (AppModel(hostStore: store, dependencies: makeDependencies(servers: servers, serverInfo: serverInfo),
                         seenStore: seenStore, now: now), host)
    }

    @Test func premierPlanRelitUnQuotaEnEchec() async throws {
        let server = try await readyServer()
        let view = try Fixtures.recorded("v3.15.1/handshake-sessions/005-result-model-selection.getView.json")
        let snapshot = try #require(try Fixtures.records(in: "v3.15.1/usage-entitlement").first { $0.file.hasPrefix("001") }).value
        let calls = Counter()
        await server.on("model-selection.getView") { _ in view }
        await server.on("usage-stats.getEntitlementSnapshot") { _ in
            if calls.next() == 1 { throw FakeRemoteError("quota indisponible") }
            return snapshot
        }
        let (app, host) = try makeApp(ServerQueue([server]))
        let usage = app.usage(for: host)
        await usage.loadIfNeeded()
        guard case .failed = usage.phase else { Issue.record("échec attendu"); return }
        await app.sceneDidBecomeActive()
        #expect(usage.phase == .ready)
        #expect(usage.fiveHoursRemaining == 96)
    }

    @Test func cachesParHoteEtProjet() async throws {
        let (app, host) = try makeApp(ServerQueue([]))
        #expect(app.connection(for: host) === app.connection(for: host))
        #expect(app.sessions(for: host, workspace: "/a") === app.sessions(for: host, workspace: "/a"))
        #expect(app.sessions(for: host, workspace: "/a") !== app.sessions(for: host, workspace: "/b"))
        let before = app.connection(for: host)
        await app.hostDidChange(host.id)                                      // adresse ou token modifiés
        #expect(app.connection(for: host) !== before)
        #expect(app.builder.clientId == "client-test")
    }

    @Test func extensionsParHoteEtPortee() async throws {
        let (app, hostA) = try makeApp(ServerQueue([]))
        let hostB = try app.hostStore.add(name: "Steam", url: "steam.ts.net", token: "jeton-b")
        // Même projet sur deux hôtes : jamais la même instance.
        #expect(app.subagents(for: hostA, scope: .workspace("/w")) !== app.subagents(for: hostB, scope: .workspace("/w")))
        // Même hôte et même portée : même instance ; portées différentes : instances différentes.
        #expect(app.subagents(for: hostA, scope: .user) === app.subagents(for: hostA, scope: .user))
        #expect(app.subagents(for: hostA, scope: .workspace("/w")) === app.subagents(for: hostA, scope: .workspace("/w")))
        #expect(app.subagents(for: hostA, scope: .user) !== app.subagents(for: hostA, scope: .workspace("/w")))
        #expect(app.subagents(for: hostA, scope: .workspace("/w")) !== app.subagents(for: hostA, scope: .workspace("/x")))
        #expect(app.subagents(for: hostA, scope: .user).scope == .user)
        // Mêmes règles pour les plugins.
        #expect(app.plugins(for: hostA, scope: .workspace("/w")) !== app.plugins(for: hostB, scope: .workspace("/w")))
        #expect(app.plugins(for: hostA, scope: .user) === app.plugins(for: hostA, scope: .user))
        #expect(app.plugins(for: hostA, scope: .workspace("/w")) === app.plugins(for: hostA, scope: .workspace("/w")))
        #expect(app.plugins(for: hostA, scope: .user) !== app.plugins(for: hostA, scope: .workspace("/w")))
        #expect(app.plugins(for: hostA, scope: .workspace("/w")) !== app.plugins(for: hostA, scope: .workspace("/x")))
        #expect(app.plugins(for: hostA, scope: .workspace("/w")).scope == .workspace("/w"))
        let beforeA = app.subagents(for: hostA, scope: .user)
        let beforeB = app.subagents(for: hostB, scope: .user)
        let pluginsA = app.plugins(for: hostA, scope: .user)
        let pluginsB = app.plugins(for: hostB, scope: .user)
        await app.hostDidChange(hostA.id)
        #expect(app.subagents(for: hostA, scope: .user) !== beforeA)
        #expect(app.subagents(for: hostB, scope: .user) === beforeB)
        #expect(app.plugins(for: hostA, scope: .user) !== pluginsA)
        #expect(app.plugins(for: hostB, scope: .user) === pluginsB)
    }

    @Test func catalogueSlashParHoteEtProjet() async throws {
        let (app, hostA) = try makeApp(ServerQueue([]))
        let hostB = try app.hostStore.add(name: "Steam", url: "steam.ts.net", token: "jeton-b")
        #expect(app.slashCatalog(for: hostA, workspace: "/w") === app.slashCatalog(for: hostA, workspace: "/w"))
        #expect(app.slashCatalog(for: hostA, workspace: "/w") !== app.slashCatalog(for: hostA, workspace: "/x"))
        #expect(app.slashCatalog(for: hostA, workspace: "/w") !== app.slashCatalog(for: hostB, workspace: "/w"))
        let before = app.slashCatalog(for: hostA, workspace: "/w")
        let other = app.slashCatalog(for: hostB, workspace: "/w")
        await app.hostDidChange(hostA.id)
        #expect(app.slashCatalog(for: hostA, workspace: "/w") !== before)
        #expect(app.slashCatalog(for: hostB, workspace: "/w") === other)
        #expect(other.skillsFallback == SlashCatalog.fallsBackToWorkspaceSkills)     // l'app suit la décision D2
    }

    @Test func projetAjouteVisible() throws {
        let (app, host) = try makeApp(ServerQueue([]))
        let connection = app.connection(for: host)
        try app.hostStore.addWorkspace("/Users/me/claude/zcode_ios", to: host.id)
        app.refreshHost(host.id)
        #expect(connection.workspaces == ["/Users/me/claude/zcode_ios"])
    }

    @Test func adresseDeLInterfaceWeb() async throws {
        let (app, host) = try makeApp(ServerQueue([]))
        #expect(app.webInterfaceURL(for: host)?.absoluteString == "https://mac.ts.net/?token=jeton")
        await app.removeHost(host.id)
        #expect(app.hostStore.hosts.isEmpty)
        #expect(app.webInterfaceURL(for: host) == nil)
    }

    @Test func premierPlanRelanceUneListeEnEchec() async throws {
        let attempts = Counter()
        let firstSeries = HostConnection.retryDelays.count
        let server = try await sessionsServer()
        let (app, host) = try makeApp(ServerQueue([server]), serverInfo: {
            // Toute la première série de tentatives échoue (iPhone hors réseau), la suivante aboutit.
            if attempts.next() <= firstSeries { throw ServerInfoError.network("hors ligne") }
            return makeServerInfo()
        })
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        guard case .failed = sessions.phase else { Issue.record("échec attendu"); return }
        await app.sceneDidBecomeActive()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
    }

    @Test func conversationsEnCache() async throws {
        let (app, host) = try makeApp(ServerQueue([]))
        let first = app.conversation(for: host, workspace: "/a", sessionId: "s1")
        #expect(app.conversation(for: host, workspace: "/a", sessionId: "s1") === first)
        #expect(app.conversation(for: host, workspace: "/a", sessionId: "s2") !== first)
        await app.hostDidChange(host.id)
        #expect(app.conversation(for: host, workspace: "/a", sessionId: "s1") !== first)
    }

    @Test func premierPlanRelanceLaConversationOuverte() async throws {
        let first = try await conversationServer()
        let second = try await conversationServer()
        let servers = ServerQueue([first, second])
        let (app, host) = try makeApp(servers)
        let conversation = app.conversation(for: host, workspace: testWorkspacePath, sessionId: pongSession)
        await conversation.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { conversation.phase == .ready ? true : nil }
        first.transport.close()                                          // socket mort pendant la veille
        await app.sceneDidBecomeActive()
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { conversation.phase == .ready && servers.opened == 2 ? true : nil }
    }

    @Test func suppressionOublieLaConversation() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
                     "revisionAtDecision": .number(0)])
        }
        let (app, host) = try makeApp(ServerQueue([server]))
        let before = app.conversation(for: host, workspace: testWorkspacePath, sessionId: "sess_a")
        try await app.deleteSession(host: host, workspace: testWorkspacePath, sessionId: "sess_a")
        #expect(app.conversation(for: host, workspace: testWorkspacePath, sessionId: "sess_a") !== before)
    }

    /// `stop()` change `phase` et fait réévaluer l'écran avant qu'il se ferme : la conversation doit rester celle du cache.
    @Test func suppressionNeRecreePasLaConversationPendantSonArret() async throws {
        let server = try await conversationServer()
        let (app, host) = try makeApp(ServerQueue([server]))
        let conversation = app.conversation(for: host, workspace: testWorkspacePath, sessionId: pongSession)
        await conversation.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { conversation.phase == .ready ? true : nil }
        let seen = Recorder<Bool>()
        withObservationTracking({ _ = conversation.phase }, onChange: {
            Task { @MainActor in           // l'écran réévalue `body`, qui redemande la conversation
                seen.append(app.conversation(for: host, workspace: testWorkspacePath, sessionId: pongSession) === conversation)
            }
        })
        try await app.deleteSession(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        _ = try await eventually { seen.all.isEmpty ? nil : true }
        #expect(seen.all == [true])
        #expect(app.conversation(for: host, workspace: testWorkspacePath, sessionId: pongSession) !== conversation)
    }

    @Test func conversationOuverteJamaisNonLue() async throws {
        let server = try await sessionsServer()
        let (app, host) = try makeApp(ServerQueue([server]))
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        app.conversationDidAppear(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        let later = Date().timeIntervalSince1970 * 1000 + 60_000                  // l'agent travaille, écran ouvert
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON(pongSession, lastActivityAt: later)))
        let busy = try await eventually { sessions.sessions.first?.lastActivityAt == later ? sessions.sessions.first : nil }
        #expect(!sessions.isUnread(busy))
        app.conversationDidDisappear(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        #expect(!sessions.isUnread(busy))                                         // vue jusqu'à cette activité
        let after = later + 1_000
        let upsert = JSONValue.object(["op": .string("session.upserted"),
                                       "session": summaryJSON(pongSession, lastActivityAt: after)])
        await server.emit(indexEvent, try indexDelta([upsert], fromSeq: 2))
        let moved = try await eventually { sessions.sessions.first?.lastActivityAt == after ? sessions.sessions.first : nil }
        #expect(sessions.isUnread(moved))                                         // activité après la fermeture
    }

    @Test func vuPoseAuPassageEnArrierePlan() async throws {
        let server = try await sessionsServer()
        let persistence = InMemoryLocalPersistence()
        let later = 1_791_890_000_000.0 + 60_000                                  // activité reçue écran ouvert
        let (app, host) = try makeApp(ServerQueue([server]), seenStore: SeenStore(persistence: persistence),
                                      now: { Date(timeIntervalSince1970: (later + 5_000) / 1000) })
        let sessions = app.sessions(for: host, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        app.conversationDidAppear(host: host, workspace: testWorkspacePath, sessionId: pongSession)
        await server.emit(indexEvent, try indexDelta(upserting: summaryJSON(pongSession, lastActivityAt: later)))
        _ = try await eventually { sessions.sessions.first?.lastActivityAt == later ? true : nil }
        app.sceneDidEnterBackground()                                             // iOS peut tuer l'app ici
        let key = SessionKey(hostId: host.id, workspace: testWorkspacePath, sessionId: pongSession)
        #expect(app.seenStore.openSessions.contains(key))                         // toujours ouverte
        let relaunched = SeenStore(persistence: persistence)                      // relancement
        #expect(!relaunched.isUnread(key, lastActivityAt: later))
        #expect(relaunched.lastSeen(key) == later + 5_000)                        // horloge injectée
    }

    @Test func conversationEnLectureSeuleEnCache() async throws {
        let (app, host) = try makeApp(ServerQueue([]))
        let child = app.conversation(for: host, workspace: "/a", sessionId: "sess_subagent_agent_x", readOnly: true)
        #expect(child.readOnly)
        #expect(child.catalog == nil)                                     // aucun catalogue de modèles pour un enfant
        #expect(app.conversation(for: host, workspace: "/a", sessionId: "sess_subagent_agent_x", readOnly: true) === child)
        #expect(app.conversation(for: host, workspace: "/a", sessionId: "s1").readOnly == false)
    }
}
