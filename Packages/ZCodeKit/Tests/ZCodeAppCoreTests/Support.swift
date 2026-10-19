import Foundation
import Synchronization
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

let testWorkspacePath = "/Users/me/claude"
let testHost = Host(name: "Mac", baseURL: URL(string: "https://mac.ts.net")!)
let testEndpoint = HostEndpoint(baseURL: URL(string: "https://mac.ts.net")!, token: "jeton")
let indexEvent = "zcode-agent.onDynamicSessionsIndexFrame"

func makeServerInfo(version: String = "3.15.1", workspaces: [String] = [testWorkspacePath]) -> ServerInfo {
    try! V4JSON.decode(ServerInfo.self, from: .object([
        "serverId": .string("srv"), "name": .string("MacBook"), "version": .string(version),
        "protocolVersion": .number(1), "authRequired": .bool(true),
        "workspaces": .array(workspaces.map { .object(["path": .string($0)]) }),
        "capabilities": .object([:]),
    ]))
}

/// Faux serveur prêt pour le handshake (hello réel de ZCode 3.15.1, version de protocole ajustable).
func readyServer(protocolVersion: Int = 3) async throws -> FakeZCodeServer {
    let server = FakeZCodeServer()
    var hello = try #require(Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json").objectValue)
    hello["protocolVersion"] = .number(Double(protocolVersion))
    let helloValue = JSONValue.object(hello)
    await server.on("zcode-agent.helloConversationV4") { _ in helloValue }
    await server.on("zcode-agent.initializeConversationV4") { _ in .null }
    await server.start()
    return server
}

/// Serveur prêt pour l'index des sessions (accusé réel ; la trame initiale est émise par le test).
func sessionsServer() async throws -> FakeZCodeServer {
    let server = try await readyServer()
    let ack = try Fixtures.recorded("v3.15.1/handshake-sessions/003-result-zcode-agent.subscribeSessionsIndexV4.json")
    await server.on("zcode-agent.subscribeSessionsIndexV4") { _ in ack }
    await server.on("zcode-agent.unsubscribeSessionsIndexV4") { _ in .null }
    return server
}

func initialIndexFrame() throws -> JSONValue {
    try Fixtures.recorded("v3.15.1/handshake-sessions/004-event-zcode-agent.onDynamicSessionsIndexFrame.json")
}

/// Trame « deltas » qui suit la trame initiale réelle (seq 1 → 2, ordinal 2) et publie `session`.
func indexDelta(upserting session: JSONValue) throws -> JSONValue {
    try indexDelta([.object(["op": .string("session.upserted"), "session": session])], fromSeq: 1)
}

/// Trame « deltas » de `fromSeq` à `fromSeq + 1` (ordinal `fromSeq + 1`), à la suite de la trame initiale réelle (seq 1).
func indexDelta(_ deltas: [JSONValue], fromSeq: Int) throws -> JSONValue {
    var wire = try #require(initialIndexFrame().objectValue)
    var frame = try #require(wire["frame"]?.objectValue)
    frame["fromSeq"] = .number(Double(fromSeq))
    frame["toSeq"] = .number(Double(fromSeq + 1))
    frame["payload"] = .object(["kind": .string("deltas"), "deltas": .array(deltas)])
    wire["frame"] = .object(frame)
    wire["logicalFrameOrdinal"] = .number(Double(fromSeq + 1))
    wire["deliveryKind"] = .string("online")
    return .object(wire)
}

func summaryJSON(_ sessionId: String, title: String = "Nouvelle", phase: String = "draft",
                 lastActivityAt: Double = 1_791_890_000_000, pendingPermissions: Int = 0,
                 preview: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "sessionId": .string(sessionId), "workspaceId": .string(testWorkspacePath), "title": .string(title),
        "phase": .string(phase), "sessionEnded": .bool(false), "hasBackgroundWork": .bool(false),
        "lastActivityAt": .number(lastActivityAt), "createdAt": .number(1_791_890_000_000),
    ]
    if pendingPermissions > 0 {
        object["pendingInteractionSummary"] = .object([
            "permissionCount": .number(Double(pendingPermissions)), "userInputCount": .number(0),
        ])
    }
    if let preview { object["lastAssistantPreview"] = .string(preview) }
    return .object(object)
}

/// Résumé décodé (tests de mise en page de la liste).
func makeSummary(_ sessionId: String, title: String = "Nouvelle", lastActivityAt: Double = 1_791_890_000_000,
             phase: String = "draft", pendingPermissions: Int = 0, preview: String? = nil) throws -> SessionSummary {
    try V4JSON.decode(SessionSummary.self, from: summaryJSON(sessionId, title: title, phase: phase,
                                                             lastActivityAt: lastActivityAt,
                                                             pendingPermissions: pendingPermissions, preview: preview))
}

/// Trame de l'index réécrite pour l'abonnement de `workspace` (sujet `sessions-index/<chemin>`) : `TopicFeed` ignore
/// les trames d'un autre sujet, un même faux serveur sert donc l'index de plusieurs projets.
func retopic(_ value: JSONValue, _ workspace: String) throws -> JSONValue {
    var wire = try #require(value.objectValue)
    var frame = try #require(wire["frame"]?.objectValue)
    let topic = JSONValue.string(Topic.sessionsIndex(workspace))
    frame["topic"] = topic
    wire["frame"] = .object(frame)
    wire["topic"] = topic
    return .object(wire)
}

/// Trame initiale réelle de l'index de `workspace`, avec `sessions` pour instantané.
func snapshotFrame(_ workspace: String, _ sessions: [JSONValue]) throws -> JSONValue {
    var wire = try #require(initialIndexFrame().objectValue)
    var frame = try #require(wire["frame"]?.objectValue)
    var payload = try #require(frame["payload"]?.objectValue)
    var snapshot = try #require(payload["snapshot"]?.objectValue)
    snapshot["sessions"] = .array(sessions)
    snapshot["workspaceId"] = .string(workspace)
    payload["snapshot"] = .object(snapshot)
    frame["payload"] = .object(payload)
    wire["frame"] = .object(frame)
    return try retopic(.object(wire), workspace)
}

/// Émet `value` sur l'index dès qu'une écoute est ouverte.
func emitWhenListening(_ server: FakeZCodeServer, _ value: JSONValue) async throws {
    _ = try await eventually { await server.listenerCount(indexEvent) > 0 ? true : nil }
    await server.emit(indexEvent, value)
}

/// Serveurs ouverts successivement : chaque connexion prend le suivant.
final class ServerQueue: Sendable {
    private let state: Mutex<(pending: [FakeZCodeServer], opened: Int)>

    init(_ servers: [FakeZCodeServer]) {
        state = Mutex((servers, 0))
    }

    var opened: Int { state.withLock { $0.opened } }

    /// Serveur rendu disponible plus tard (l'hôte redevient joignable).
    func append(_ server: FakeZCodeServer) {
        state.withLock { $0.pending.append(server) }
    }

    func next() -> FakeZCodeServer? {
        state.withLock { state in
            guard !state.pending.isEmpty else { return nil }
            state.opened += 1
            return state.pending.removeFirst()
        }
    }
}

final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    func append(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

/// Interrupteur partagé entre un test et les gestionnaires d'un faux serveur (état de l'hôte qui change).
final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

func makeDependencies(
    servers: ServerQueue,
    sleeps: Recorder<Duration> = Recorder(),
    serverInfoDelay: Duration = .zero,
    serverInfo: @escaping @Sendable () throws -> ServerInfo = { makeServerInfo() }
) -> ConnectionDependencies {
    ConnectionDependencies(
        fetchServerInfo: { _ in
            if serverInfoDelay > .zero { try await Task.sleep(for: serverInfoDelay) }
            return try serverInfo()
        },
        openChannel: { _ in
            guard let server = servers.next() else {
                throw RPCError.transport(.connectionFailed("aucun serveur disponible"))
            }
            let client = ChannelClient(transport: server.transport)
            await client.start()
            try await client.ready()
            return client
        },
        sleep: { sleeps.append($0) },
        clientId: "client-test",
        appVersion: "test"
    )
}

let conversationEvent = "zcode-agent.onDynamicConversationFrame"
/// Session de la conversation PONG enregistrée (`v3.15.1/send-text`).
let pongSession = "sess_45199523-12a0-4928-92e6-ff082723da62"

/// Valeur d'un enregistrement de `send-text` choisi par son préfixe (`"004"`, `"006"`…).
func conversationRecord(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/send-text").first { $0.file.hasPrefix(prefix) }).value
}

/// Accusé « accepté » pour l'enveloppe reçue.
func acceptedAck(_ argument: JSONValue, delivery: String = "startNow") -> JSONValue {
    .object([
        "commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("accepted"),
        "revisionAtDecision": .number(9),
        "result": .object(["type": .string("inputAccepted"), "delivery": .string(delivery), "inputId": .string("i")]),
    ])
}

/// Serveur prêt pour la conversation PONG : accusé d'abonnement réel, commandes acceptées.
func conversationServer() async throws -> FakeZCodeServer {
    let server = try await readyServer()
    let ack = try conversationRecord("003")
    await server.on("zcode-agent.subscribeConversationV4") { _ in ack }
    await server.on("zcode-agent.unsubscribeConversationV4") { _ in .null }
    await server.on("zcode-agent.sendConversationCommandV4") { acceptedAck($0) }
    return server
}

/// Trame initiale réelle (`send-text/004`, seq 13) dont le snapshot est retouché par `edit`.
func initialConversationFrame(_ edit: (inout [String: JSONValue]) throws -> Void = { _ in }) throws -> JSONValue {
    var wire = try #require(conversationRecord("004").objectValue)
    var frame = try #require(wire["frame"]?.objectValue)
    var payload = try #require(frame["payload"]?.objectValue)
    var snapshot = try #require(payload["snapshot"]?.objectValue)
    try edit(&snapshot)
    payload["snapshot"] = .object(snapshot)
    frame["payload"] = .object(payload)
    wire["frame"] = .object(frame)
    return .object(wire)
}

/// Émet `value` sur les conversations dès qu'une écoute est ouverte.
func emitConversation(_ server: FakeZCodeServer, _ value: JSONValue) async throws {
    _ = try await eventually { await server.listenerCount(conversationEvent) > 0 ? true : nil }
    await server.emit(conversationEvent, value)
}

@MainActor
func makeConversation(_ servers: ServerQueue, sessionId: String = pongSession,
                      retryDelays: [Duration] = ConversationModel.defaultReconcileRetryDelays,
                      cache: ConversationCache? = nil,
                      now: @escaping @Sendable () -> Date = Date.init) -> ConversationModel {
    let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
    return ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                             workspace: testWorkspacePath, sessionId: sessionId, cache: cache,
                             cacheKey: cache.map { _ in SessionKey(hostId: testHost.id, workspace: testWorkspacePath,
                                                                   sessionId: sessionId) },
                             now: now, reconcileRetryDelays: retryDelays)
}

/// Conversation prête sur la trame réelle `send-text/004` ; `edit` retouche le snapshot (Goal, disponibilité, routage…).
@MainActor
func readyConversation(_ server: FakeZCodeServer, _ edit: @escaping (inout [String: JSONValue]) -> Void = { _ in }) async throws
    -> ConversationModel {
    let model = makeConversation(ServerQueue([server]))
    await model.start()
    try await emitConversation(server, initialConversationFrame { edit(&$0) })
    _ = try await eventually { model.phase == .ready ? true : nil }
    return model
}

extension ConversationModel {
    /// Nombre de tours affichés (une entrée ouvre un tour).
    var turnCount: Int { entries.filter(\.startsTurn).count }
}

/// Premier serveur dont la connexion tombe pendant l'envoi ; second serveur qui répond à la requête de rapprochement
/// (`queryResult` reçoit la clé interrogée).
func cutAndResumeServers(
    queryResult: @escaping @Sendable (JSONValue) -> JSONValue
) async throws -> (FakeZCodeServer, FakeZCodeServer, ServerQueue) {
    let first = try await conversationServer()
    let transport = first.transport
    await first.on("zcode-agent.sendConversationCommandV4") { _ in
        transport.finish()                                     // coupure : l'accusé ne repartira jamais
        return .null
    }
    let second = try await conversationServer()
    await second.on("zcode-agent.queryConversationCommandsV4") { argument in
        let key = argument["commands"]?.arrayValue?.first ?? .null
        return .object(["results": .array([.object(["key": key, "result": queryResult(key)])])])
    }
    return (first, second, ServerQueue([first, second]))
}

/// Demande type de `synthetic/interactions-v3.15.1.json` (`perm_bash`, `ask_style`, `plan_1`, `input_key`, `perm_sub`,
/// `hook_1`).
func syntheticInteraction(_ id: String) throws -> JSONValue {
    let list = try #require(Fixtures.file("synthetic/interactions-v3.15.1.json")["pendingInteractions"]?.arrayValue)
    return try #require(list.first { $0["interactionId"]?.stringValue == id })
}

/// Trame « deltas » qui suit la trame initiale réelle (`send-text/004`, seq 13) : seq `fromSeq` → `fromSeq + 1`.
func conversationDeltas(_ deltas: [JSONValue], fromSeq: Int = 13, ordinal: Int = 2) throws -> JSONValue {
    var wire = try #require(conversationRecord("006").objectValue)
    var frame = try #require(wire["frame"]?.objectValue)
    frame["fromSeq"] = .number(Double(fromSeq))
    frame["toSeq"] = .number(Double(fromSeq + 1))
    frame["payload"] = .object(["kind": .string("deltas"), "deltas": .array(deltas)])
    wire["frame"] = .object(frame)
    wire["logicalFrameOrdinal"] = .number(Double(ordinal))
    wire["logicalFrameId"] = .string("test-frame-\(ordinal)")
    return .object(wire)
}

/// `state.updated` qui remplace les demandes en attente (comme l'hôte : liste entière à chaque changement).
func pendingPatch(_ interactions: [JSONValue], revision: Int = 10) -> JSONValue {
    .object(["op": .string("state.updated"), "patch": .object([
        "pendingInteractions": .array(interactions), "revision": .number(Double(revision)),
    ])])
}
