import Foundation
import Testing
import ZCodeClient

struct URLSessionTests {
    /// Les URL de l'hôte portent le token (`?token=`) : rien ne doit finir dans `Cache.db`.
    @Test func sessionSansCache() {
        let configuration = URLSession.zcode.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }
}
