import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeV4
import ZCodeWire

@MainActor
struct HostStoreTests {
    let persistence = InMemoryHostPersistence()
    let tokens = InMemoryTokenStore()

    func store() -> HostStore { HostStore(persistence: persistence, tokens: tokens) }

    @Test func adresseNettoyee() throws {
        #expect(try Host.normalizedURL("macbook.your-tailnet.ts.net") == URL(string: "https://macbook.your-tailnet.ts.net")!)
        #expect(try Host.normalizedURL("  https://Mac.ts.net/?token=secret#x ") == URL(string: "https://Mac.ts.net")!)
        #expect(try Host.normalizedURL("https://mac.ts.net:8443/ui") == URL(string: "https://mac.ts.net:8443")!)
        #expect(throws: HostValidationError.insecureURL) { try Host.normalizedURL("http://mac.ts.net") }
        #expect(throws: HostValidationError.invalidURL) { try Host.normalizedURL("") }
        #expect(throws: HostValidationError.invalidURL) { try Host.normalizedURL("https://") }
    }

    @Test func ajoutPersisteSansLeToken() throws {
        let hosts = store()
        let host = try hosts.add(name: " MacBook Pro ", url: "https://mac.ts.net/?token=abc", token: " jeton ")
        #expect(host.name == "MacBook Pro")
        #expect(hosts.token(for: host.id) == "jeton")
        let saved = String(decoding: try #require(persistence.load()), as: UTF8.self)
        #expect(!saved.contains("jeton"))
        #expect(!saved.contains("abc"))
        #expect(store().hosts == [host])                                  // relu depuis la persistance
        #expect(hosts.endpoint(for: host) == HostEndpoint(baseURL: URL(string: "https://mac.ts.net")!, token: "jeton"))
    }

    @Test func validation() {
        let hosts = store()
        #expect(throws: HostValidationError.emptyName) { try hosts.add(name: "  ", url: "mac.ts.net", token: "t") }
        #expect(throws: HostValidationError.emptyToken) { try hosts.add(name: "Mac", url: "mac.ts.net", token: " ") }
        #expect(throws: HostValidationError.insecureURL) { try hosts.add(name: "Mac", url: "http://mac.ts.net", token: "t") }
        #expect(hosts.hosts.isEmpty)
        #expect(HostValidationError.insecureURL.message.contains("https"))
    }

    @Test func modificationEtSuppression() throws {
        let hosts = store()
        let host = try hosts.add(name: "Mac", url: "mac.ts.net", token: "ancien")
        try hosts.update(host.id, name: "Mac Studio", url: "studio.ts.net", token: nil)
        #expect(hosts.host(id: host.id)?.name == "Mac Studio")
        #expect(hosts.token(for: host.id) == "ancien")                     // token inchangé si non fourni
        try hosts.update(host.id, name: "Mac Studio", url: "studio.ts.net", token: "nouveau")
        #expect(hosts.token(for: host.id) == "nouveau")
        hosts.remove(host.id)
        #expect(hosts.hosts.isEmpty)
        #expect(hosts.token(for: host.id) == nil)
    }

    @Test func projetsManuels() throws {
        let hosts = store()
        let host = try hosts.add(name: "Mac", url: "mac.ts.net", token: "t")
        try hosts.addWorkspace(" /Users/me/claude/zcode_ios/ ", to: host.id)
        try hosts.addWorkspace("/Users/me/claude/zcode_ios", to: host.id)   // doublon ignoré
        #expect(throws: HostValidationError.invalidWorkspace) { try hosts.addWorkspace("relatif", to: host.id) }
        #expect(hosts.host(id: host.id)?.manualWorkspaces == ["/Users/me/claude/zcode_ios"])
        hosts.removeWorkspace("/Users/me/claude/zcode_ios", from: host.id)
        #expect(hosts.host(id: host.id)?.manualWorkspaces == [])
    }

    @Test func amorcageDeDebogage() throws {
        let hosts = store()
        try hosts.add(name: "Ancien", url: "ancien.ts.net", token: "t")
        let environment = ["ZCODE_RESET": "1", "ZCODE_SEED_NAME": "Mac (test)",
                           "ZCODE_SEED_URL": "https://mac.ts.net", "ZCODE_SEED_TOKEN": "jeton"]
        hosts.applyDebugSeed(environment: environment)
        hosts.applyDebugSeed(environment: environment.filter { $0.key != "ZCODE_RESET" })   // pas de doublon
        #expect(hosts.hosts.map(\.name) == ["Mac (test)"])
        #expect(hosts.token(for: hosts.hosts[0].id) == "jeton")
        hosts.applyDebugSeed(environment: [:])
        #expect(hosts.hosts.count == 1)
    }

    @Test func amorcageDeDeuxHotes() throws {
        let hosts = store()
        try hosts.add(name: "Ancien", url: "ancien.ts.net", token: "t")
        let environment = ["ZCODE_RESET": "1",
            "ZCODE_SEED_NAME": "Mac (test)", "ZCODE_SEED_URL": "https://mac.ts.net", "ZCODE_SEED_TOKEN": "jeton",
            "ZCODE_SEED2_NAME": "Steam (test)", "ZCODE_SEED2_URL": "https://steam.ts.net", "ZCODE_SEED2_TOKEN": "jeton2"]
        hosts.applyDebugSeed(environment: environment)
        hosts.applyDebugSeed(environment: environment.filter { $0.key != "ZCODE_RESET" })   // pas de doublon
        #expect(hosts.hosts.map(\.name) == ["Mac (test)", "Steam (test)"])
        #expect(hosts.token(for: hosts.hosts[1].id) == "jeton2")
    }

    @Test func libelles() throws {
        #expect(SessionPhase.running.label == "En cours")
        #expect(SessionPhase.running.isBusy)
        #expect(SessionPhase(rawValue: "hibernating").label == "hibernating")
        let summary = try V4JSON.decode(SessionSummary.self, from: .object([
            "sessionId": .string("s"), "workspaceId": .string("/w"), "title": .string("T"), "phase": .string("running"),
            "lastActivityAt": .number(1_791_885_165_838),
            "pendingInteractionSummary": .object(["permissionCount": .number(1), "userInputCount": .number(2)]),
        ]))
        #expect(summary.pendingCount == 3)
        #expect(summary.lastActivityDate == Date(timeIntervalSince1970: 1_791_885_165.838))
    }

    @Test func modeParDefautPersiste() throws {
        let hosts = store()
        let host = try hosts.add(name: "Mac", url: "mac.ts.net", token: "t")
        #expect(hosts.host(id: host.id)?.defaultMode == nil)
        hosts.setDefaultMode("yolo", for: host.id)
        #expect(hosts.host(id: host.id)?.defaultMode == "yolo")
        #expect(store().host(id: host.id)?.defaultMode == "yolo")                   // relu depuis la persistance
        hosts.setDefaultMode(nil, for: host.id)
        #expect(store().host(id: host.id)?.defaultMode == nil)
    }

    @Test func hoteAncienSansModeParDefaut() throws {
        // Enregistrement d'avant la Phase 13 : aucune clé `defaultMode`.
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Mac","baseURL":"https://mac.ts.net","manualWorkspaces":["/w"]}]"#
        persistence.save(Data(json.utf8))
        let host = try #require(store().host(id: id))
        #expect(host.name == "Mac")
        #expect(host.baseURL == URL(string: "https://mac.ts.net")!)
        #expect(host.manualWorkspaces == ["/w"])
        #expect(host.defaultMode == nil)
    }
}
