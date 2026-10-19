import Foundation
import Testing
import ZCodeClient

struct HostEndpointTests {
    @Test func urlsDUnHoteTailscale() {
        let endpoint = HostEndpoint(baseURL: URL(string: "https://mac.your-tailnet.ts.net")!, token: "abc-_9")
        #expect(endpoint.webSocketURL.absoluteString == "wss://mac.your-tailnet.ts.net/ws?token=abc-_9")
        #expect(endpoint.serverInfoURL.absoluteString == "https://mac.your-tailnet.ts.net/api/server-info?token=abc-_9")
        #expect(endpoint.webUIURL.absoluteString == "https://mac.your-tailnet.ts.net/?token=abc-_9")
    }

    @Test func urlsDUnHoteLocal() {
        let endpoint = HostEndpoint(baseURL: URL(string: "http://127.0.0.1:3030")!, token: "t")
        #expect(endpoint.webSocketURL.absoluteString == "ws://127.0.0.1:3030/ws?token=t")
    }

    @Test func encodeLesCaracteresSpeciauxDuToken() {
        let endpoint = HostEndpoint(baseURL: URL(string: "https://h.ts.net")!, token: "a+b/c=é")
        #expect(endpoint.serverInfoURL.absoluteString == "https://h.ts.net/api/server-info?token=a%2Bb%2Fc%3D%C3%A9")
    }

    @Test func neDevoilePasLeTokenQuandOnLImprime() {
        let endpoint = HostEndpoint(baseURL: URL(string: "https://h.ts.net")!, token: "secret")
        var dumped = ""
        dump(endpoint, to: &dumped)
        #expect(!"\(endpoint)".contains("secret"))
        #expect(!String(reflecting: endpoint).contains("secret"))
        #expect(!dumped.contains("secret"))
        #expect("\(endpoint)".contains("https://h.ts.net"))
    }
}
