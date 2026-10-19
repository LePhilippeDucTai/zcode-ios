import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

let testWorkspace = "/Users/me/claude"

/// Client connecté à un serveur simulé : chaque test joue le rôle de ZCode.
func connectedAgent(workspacePath: String = testWorkspace) async -> (AgentV4, InMemoryTransport) {
    let transport = InMemoryTransport()
    let client = ChannelClient(transport: transport)
    await client.start()
    transport.deliverInitialize()
    return (AgentV4(client: client, workspacePath: workspacePath), transport)
}

func agentCall(_ id: Int32, _ method: String) -> RPCValue {
    .array([.int(100), .int(id), .string("zcode-agent"), .string(method)])
}

struct AgentV4Tests {
    @Test func handshakeHelloPuisClientHello() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        async let hello = agent.handshake(clientId: "client-x", appVersion: "test")
        let first = try decodeSent(#require(await sent.next()))
        #expect(first.header == agentCall(0, "helloConversationV4"))
        #expect(first.body == .array([]))
        transport.respond(to: 0, with: try Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json"))
        let second = try decodeSent(#require(await sent.next()))
        #expect(second.header == agentCall(1, "initializeConversationV4"))
        #expect(second.body == .array([.json(ClientHello(clientId: "client-x", appVersion: "test").json)]))
        transport.respond(to: 1, with: .null)
        #expect(try await hello.protocolVersion == 3)
    }

    @Test func versionDeProtocoleInconnueBloque() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let handshake = Task { try await agent.handshake(clientId: "client-x", appVersion: "test") }
        _ = await sent.next()
        var hello = try #require(Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json").objectValue)
        hello["protocolVersion"] = .number(4)
        transport.respond(to: 0, with: .object(hello))
        await #expect(throws: AgentV4Error.unsupportedProtocol(4)) { try await handshake.value }
    }

    @Test func abonnementEtCommande() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        async let ack = agent.subscribeConversation(sessionId: "sess_1", base: Watermark(logEpoch: "e1", seq: 13))
        let subscribe = try decodeSent(#require(await sent.next()))
        #expect(subscribe.header == agentCall(0, "subscribeConversationV4"))
        #expect(subscribe.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "sessionId": .string("sess_1"),
            "base": .object(["logEpoch": .string("e1"), "seq": .number(13)]),
        ]))]))
        transport.respond(to: 0, with: try Fixtures.recorded("v3.15.1/send-text/003-result-zcode-agent.subscribeConversationV4.json"))
        #expect(try await ack.subscriptionId == "sub-mv6j6gf9-m0d4m1jc-2")

        let command = CommandBuilder(clientId: "client-x").sendText(sessionId: "sess_1", text: "Bonjour")
        async let commandAck = agent.send(command)
        let request = try decodeSent(#require(await sent.next()))
        #expect(request.header == agentCall(1, "sendConversationCommandV4"))
        #expect(request.body == .array([.json(.object(["workspacePath": .string(testWorkspace), "envelope": command.json]))]))
        transport.respond(to: 1, with: .object([
            "commandId": .string(command.commandId), "status": .string("accepted"), "revisionAtDecision": .number(10),
        ]))
        #expect(try await commandAck.isAccepted)
    }

    @Test func resyncSansBaseEcritNull() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        async let ack = agent.resyncConversation(subscriptionId: "sub-1", base: nil, forceSnapshot: true)
        let request = try decodeSent(#require(await sent.next()))
        #expect(request.header == agentCall(0, "resyncConversationV4"))
        #expect(request.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "subscriptionId": .string("sub-1"), "base": .null, "forceSnapshot": .bool(true),
        ]))]))
        transport.respond(to: 0, with: .object(["ack": .object([
            "subscriptionId": .string("sub-1"), "mode": .string("snapshot"), "logEpoch": .string("e2"),
        ])]))
        #expect(try await ack.mode == .snapshot)
    }

    @Test func fluxDeTrames() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        let frames = try await agent.conversationFrames()
        let listen = try decodeSent(#require(await sent.next()))
        #expect(listen.header == .array([.int(102), .int(0), .string("zcode-agent"), .string("onDynamicConversationFrame")]))
        #expect(listen.body == .json(.object(["workspacePath": .string(testWorkspace)])))
        let wire = try Fixtures.recorded("v3.15.1/send-text/006-event-zcode-agent.onDynamicConversationFrame.json")
        transport.emit(listener: 0, wire)
        var iterator = frames.makeAsyncIterator()
        #expect(await iterator.next() == wire)
    }

    @Test func historiqueEtReponseMalFormee() async throws {
        let (agent, transport) = await connectedAgent()
        var sent = transport.sent.makeAsyncIterator()
        async let page = agent.rowsRange(sessionId: "sess_1", beforeRowId: 40, limit: 50)
        let request = try decodeSent(#require(await sent.next()))
        #expect(request.header == agentCall(0, "conversationRowsRangeV4"))
        #expect(request.body == .array([.json(.object([
            "workspacePath": .string(testWorkspace), "sessionId": .string("sess_1"),
            "beforeRowId": .number(40), "limit": .number(50),
        ]))]))
        transport.respond(to: 0, with: .string("inattendu"))
        do {
            _ = try await page
            Issue.record("une erreur était attendue")
        } catch AgentV4Error.malformedResponse(let method, _) {
            #expect(method == "conversationRowsRangeV4")
        }
    }
}
