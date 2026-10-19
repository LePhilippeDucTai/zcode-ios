import Foundation
import Testing
import ZCodeRPC
import ZCodeTestSupport
import ZCodeWire

struct ChannelClientTests {
    private func makeClient() async -> (ChannelClient, InMemoryTransport) {
        let transport = InMemoryTransport()
        let client = ChannelClient(transport: transport)
        await client.start()
        return (client, transport)
    }

    @Test func appelResoluApresInitialize() async throws {
        let (client, transport) = await makeClient()
        var sent = transport.sent.makeAsyncIterator()
        async let result = client.call("zcode-agent", "helloConversationV4", .array([]))
        transport.deliverInitialize()
        let request = try #require(await sent.next())
        #expect(request == RPCMessage.request(.promise, id: 0, channel: "zcode-agent", name: "helloConversationV4", arg: .array([])))
        transport.deliver(.array([.int(201), .int(0)]), .json(.object(["kind": .string("hello")])))
        #expect(try await result == .json(.object(["kind": .string("hello")])))
    }

    @Test func identifiantsCroissantsEtReponsesDansLeDesordre() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        async let first = client.call("c", "a")
        _ = try #require(await sent.next())
        async let second = client.call("c", "b")
        let secondRequest = try decodeSent(#require(await sent.next()))
        #expect(secondRequest.header == .array([.int(100), .int(1), .string("c"), .string("b")]))
        transport.deliver(.array([.int(201), .int(1)]), .string("B"))
        transport.deliver(.array([.int(201), .int(0)]), .string("A"))
        #expect(try await first == .string("A"))
        #expect(try await second == .string("B"))
    }

    @Test func erreurDistante() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        async let result = client.call("c", "m")
        _ = await sent.next()
        transport.deliver(.array([.int(202), .int(0)]), .json(.object(["message": .string("boom"), "name": .string("Error")])))
        do {
            _ = try await result
            Issue.record("une erreur était attendue")
        } catch let RPCError.remote(error) {
            #expect(error.message == "boom")
        }
    }

    @Test func objetDErreur() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let result = Task { try await client.call("c", "m") }
        _ = await sent.next()
        transport.deliver(.array([.int(203), .int(0)]), .string("brut"))
        await #expect(throws: RPCError.errorObject(.string("brut"))) { try await result.value }
    }

    @Test func evenementsDUneEcoute() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let arg = RPCValue.json(.object(["workspacePath": .string("/w")]))
        let stream = try await client.listen("zcode-agent", "onDynamicSessionsIndexFrame", arg)
        #expect(await sent.next() == RPCMessage.request(.eventListen, id: 0, channel: "zcode-agent", name: "onDynamicSessionsIndexFrame", arg: arg))
        transport.deliver(.array([.int(204), .int(0)]), .json(.object(["n": .number(1)])))
        transport.deliver(.array([.int(204), .int(0)]), .json(.object(["n": .number(2)])))
        var events = stream.makeAsyncIterator()
        #expect(await events.next() == .json(.object(["n": .number(1)])))
        #expect(await events.next() == .json(.object(["n": .number(2)])))
    }

    @Test func finDEcouteEnvoieEventDispose() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let stream = try await client.listen("c", "onDidChange")
        _ = await sent.next()
        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        #expect(await sent.next() == RPCMessage.dispose(.eventDispose, id: 0))
    }

    @Test func annulationDeTacheEnvoiePromiseCancel() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let task = Task { try await client.call("c", "lent") }
        _ = await sent.next()
        task.cancel()
        #expect(await sent.next() == RPCMessage.dispose(.promiseCancel, id: 0))
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func fermetureDuTransportFaitEchouerLesAppels() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let stream = try await client.listen("c", "onDidChange")
        _ = await sent.next()
        let pending = Task { try await client.call("c", "m") }
        _ = await sent.next()
        transport.finish()
        await #expect(throws: RPCError.connectionClosed) { try await pending.value }
        await #expect(throws: RPCError.connectionClosed) { try await client.call("c", "apres") }
        for await _ in stream {}  // le flux d'événements se termine
        #expect(transport.isClosed)
    }

    @Test func echecDuTransportTransmisAuxAppelants() async throws {
        let (client, transport) = await makeClient()
        transport.fail(TransportError.unauthorized)
        await #expect(throws: RPCError.transport(.unauthorized)) { try await client.ready() }
    }

    @Test func messageIllisibleFermeLaConnexion() async throws {
        let (client, transport) = await makeClient()
        transport.deliverInitialize()
        var sent = transport.sent.makeAsyncIterator()
        let pending = Task { try await client.call("c", "m") }
        _ = await sent.next()
        transport.deliverRaw(Data([0x07]))
        do {
            _ = try await pending.value
            Issue.record("une erreur était attendue")
        } catch RPCError.protocolViolation {
            #expect(transport.isClosed)
        }
    }

    @Test func readyAnnulableAvantInitialize() async throws {
        let (client, _) = await makeClient()
        let waiting = Task { try await client.ready() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    try await waiting.value
                    return "prêt"
                } catch is CancellationError {
                    return "annulé"
                } catch {
                    return "autre : \(error)"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                await client.close()  // débloque l'attente si l'annulation n'a pas eu d'effet
                return "bloqué"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(outcome == "annulé")
    }

    @Test func clientAbandonneFermeLeTransport() async {
        let transport = InMemoryTransport()
        do {
            let client = ChannelClient(transport: transport)
            await client.start()
        }
        #expect(transport.isClosed)
    }
}
