import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport

struct ZCodeConnectorTests {
    @Test func connecteQuandLeServeurEnvoieInitialize() async throws {
        let transport = InMemoryTransport()
        transport.deliverInitialize()
        let client = try await ZCodeConnector.connect(transport: transport, timeout: .seconds(2))
        try await client.ready()
        #expect(!transport.isClosed)
    }

    @Test func expireSansInitialize() async {
        let transport = InMemoryTransport()
        await #expect(throws: ConnectorError.timeout) {
            try await ZCodeConnector.connect(transport: transport, timeout: .milliseconds(50))
        }
        #expect(transport.isClosed)
    }

    @Test func transmetLeRefusDuToken() async {
        let transport = InMemoryTransport()
        transport.fail(TransportError.unauthorized)
        await #expect(throws: RPCError.transport(.unauthorized)) {
            try await ZCodeConnector.connect(transport: transport, timeout: .seconds(2))
        }
    }
}
