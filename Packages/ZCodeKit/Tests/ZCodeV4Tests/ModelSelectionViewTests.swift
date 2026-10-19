import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ModelSelectionViewTests {
    @Test func vueReelleGLM() throws {
        let view = try ModelSelectionView(json: Fixtures.recorded("v3.15.1/handshake-sessions/005-result-model-selection.getView.json"))
        #expect(view.revision == 1)
        #expect(view.providers.map(\.name) == ["Z.AI Individual Coding Plan"])
        #expect(view.providers.first?.models.map(\.modelId) == ["GLM-5.3", "GLM-5.3-Flash"])
        #expect(view.model(providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3")?.reasoningLevels == ["low", "high", "max"])
        #expect(view.preferredSelection == ModelSelection(
            providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3", reasoningLevel: "max"))
        // Accès par compte (sans secret) renvoyé tel quel à `usage-stats`.
        let access = try #require(view.providers.first?.accountAccess)
        #expect(access == ProviderAccountAccess(accountType: "zai", mode: "individual-coding-plan", entitled: true))
        #expect(access.canReadUsage)
        #expect(access.json == .object([
            "type": .string("zhipu-account"), "accountType": .string("zai"), "mode": .string("individual-coding-plan"),
            "entitled": .bool(true),
        ]))
    }

    @Test func mistralSansRaisonnementEtSansCle() throws {
        let view = try ModelSelectionView(json: Fixtures.file("synthetic/model-selection-mistral.json"))
        #expect(view.revision == 4)
        #expect(view.providers.map(\.providerId) == ["account:zai-individual-coding-plan", "new-provider"])   // sans id : ignoré
        let mistral = try #require(view.provider(id: "new-provider"))
        #expect(mistral.name == "Mistral")
        #expect(mistral.visibleModels.map(\.modelId) == ["mistral-large-4", "mistral-medium-latest"])          // désactivé masqué
        #expect(view.model(providerId: "new-provider", modelId: "mistral-large-4")?.reasoningLevels == ["none"])
        #expect(view.model(providerId: "new-provider", modelId: "mistral-large-4")?.contextWindow == 256_000)
        // La clé d'API de `config.access` n'est conservée nulle part ; un accès `api-key` n'a pas de compte.
        #expect(!String(describing: view).contains("cle-factice"))
        #expect(mistral.accountAccess == nil)
        // Accès par compte incomplet (sans `mode` ni `entitled`) : inutilisable, donc absent.
        #expect(view.provider(id: "account:zai-individual-coding-plan")?.accountAccess == nil)
    }

    @Test func accesParCompteStrict() {
        #expect(ProviderAccountAccess(json: .object([
            "type": .string("zhipu-account"), "accountType": .string("bigmodel"), "mode": .string("team-coding-plan"),
            "entitled": .bool(false),
        ]))?.canReadUsage == false)
        #expect(ProviderAccountAccess(json: .object([
            "type": .string("zhipu-account"), "accountType": .string("zai"), "mode": .string("off-peak"),
            "entitled": .bool(true),
        ]))?.canReadUsage == false)
        #expect(ProviderAccountAccess(json: .object([
            "type": .string("api-key"), "accountType": .string("zai"), "mode": .string("individual-coding-plan"),
            "entitled": .bool(true), "apiKey": .string("secret"),
        ])) == nil)
        #expect(ProviderAccountAccess(json: nil) == nil)
    }

    @Test func vueToleranteAuxChampsAbsents() throws {
        let view = try ModelSelectionView(json: .object(["providers": .array([.object([
            "providerId": .string("p"), "models": .array([.object(["modelId": .string("m")]), .object([:])]),
        ])])]))
        #expect(view.revision == 0)
        #expect(view.providers.first?.name == "p")
        #expect(view.model(providerId: "p", modelId: "m")?.reasoningLevels == [])
        #expect(view.model(providerId: "p", modelId: "m")?.enabled == true)
        #expect(throws: V4DecodingError.self) { try ModelSelectionView(json: .array([])) }
    }
}
