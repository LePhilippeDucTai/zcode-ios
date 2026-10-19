import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct InteractionsTests {
    struct UnexpectedPayload: Error {}

    func interactionsJSON() throws -> [JSONValue] {
        try #require(Fixtures.file("synthetic/interactions-v3.15.1.json")["pendingInteractions"]?.arrayValue)
    }

    func interactions() throws -> [PendingInteraction] {
        try interactionsJSON().compactMap(PendingInteraction.init(json:))
    }

    func permission(_ index: Int) throws -> PermissionRequest {
        guard case .permission(let request) = try interactions()[index].payload else { throw UnexpectedPayload() }
        return request
    }

    func userInput(_ index: Int) throws -> UserInputRequest {
        guard case .userInput(let request) = try interactions()[index].payload else { throw UnexpectedPayload() }
        return request
    }

    @Test func toutesLesDemandesSontLues() throws {
        let all = try interactions()
        #expect(all.map(\.interactionId) == ["perm_bash", "ask_style", "plan_1", "input_key", "perm_sub", "hook_1"])
        #expect(all.map(\.createdAt) == [1_791_890_000_000, 1_791_890_001_000, 1_791_890_002_000,
                                         1_791_890_003_000, 1_791_890_004_000, 1_791_890_005_000])
        #expect(all[5].payload == .unsupported)
    }

    @Test func autorisationAvecDetail() throws {
        let request = try permission(0)
        #expect(request.detail?["command"] == .string("rm -rf dist"))
        #expect(request.freeText == true)
        #expect(request.options.map(\.optionId) == ["allowOnce", "allowAlways", "deny"])   // « Full access » non lu
        let interaction = try interactions()[0]
        #expect(interaction.origin == nil)
        #expect(interaction.autoResolution == nil)
        #expect(interaction.anchorRowId == 7)
    }

    @Test func questionsAvecCompteARebours() throws {
        let request = try userInput(1)
        #expect(request.toolName == "AskUserQuestion")
        #expect(request.toolCallId == "call_ask")
        #expect(!request.isPlanApproval)
        #expect(request.planText == nil)
        #expect(request.questions?.map(\.multiSelect) == [false, true])
        #expect(request.questions?[0].options[1].preview == "<div>aperçu</div>")
        let auto = try #require(try interactions()[1].autoResolution)
        #expect(auto.state == "visibleCountdown")
        #expect(!auto.isSnoozed)
        let deadline = Date(timeIntervalSince1970: 1_791_890_301)
        #expect(auto.countdownSeconds(now: deadline.addingTimeInterval(-90)) == nil)     // plus d'une minute : caché
        #expect(auto.countdownSeconds(now: deadline.addingTimeInterval(-42.5)) == 42)
        #expect(auto.countdownSeconds(now: deadline.addingTimeInterval(-0.2)) == 1)
        #expect(auto.countdownSeconds(now: deadline) == nil)                             // échéance passée
    }

    @Test func approbationDuPlan() throws {
        let request = try userInput(2)
        #expect(request.isPlanApproval)
        #expect(request.planText == "## Plan\n\n1. Ajouter le test\n2. Corriger le bug")
        #expect(request.questions?.first?.options.map(\.value) == ["approve"])
    }

    @Test func saisieSensibleEtSousAgent() throws {
        let input = try userInput(3)
        #expect(input.sensitive == true)
        #expect(input.questions == nil)
        #expect(input.planText == nil)
        let request = try permission(4)
        #expect(request.options.map(\.kind.rawValue) == ["allowOnce", "allowAlways", "deny", "escalate", "custom"])
        let origin = try #require(try interactions()[4].origin)
        #expect(origin.kind == "subagent")
        #expect(origin.agentType == "explorer")
        #expect(origin.description == "Analyse")
    }

    @Test func compteAReboursSuspenduOuIllisible() throws {
        var json = try #require(try interactionsJSON()[1].objectValue)
        json["autoResolution"] = .object(["state": .string("snoozed"), "startedAt": .number(1), "snoozedAt": .number(2)])
        let snoozed = try #require(PendingInteraction(json: .object(json)))
        #expect(snoozed.autoResolution?.isSnoozed == true)
        #expect(snoozed.autoResolution?.countdownSeconds(now: Date()) == nil)
        json["autoResolution"] = .string("illisible")
        let unreadable = try #require(PendingInteraction(json: .object(json)))
        #expect(unreadable.autoResolution == nil)                                        // la question reste
        guard case .userInput = unreadable.payload else { Issue.record("question attendue"); return }
    }

    @Test func provenanceIllisibleSansPerdreLaDemande() throws {
        var json = try #require(try interactionsJSON()[4].objectValue)
        var payload = try #require(json["payload"]?.objectValue)
        payload["origin"] = .string("inconnue")
        json["payload"] = .object(payload)
        let interaction = try #require(PendingInteraction(json: .object(json)))
        #expect(interaction.origin == nil)
        guard case .permission = interaction.payload else { Issue.record("autorisation attendue"); return }
    }
}
