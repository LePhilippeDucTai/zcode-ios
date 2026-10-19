import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct ComposerSettingsTests {
    let view: ModelSelectionView
    let glm = ModelSelection(providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3", reasoningLevel: "max")

    init() throws {
        view = try ModelSelectionView(json: Fixtures.file("synthetic/model-selection-mistral.json"))
    }

    func config(_ fields: [String: JSONValue]) throws -> SessionConfig {
        var object: [String: JSONValue] = [
            "provider": .string("account:zai-individual-coding-plan"), "model": .string("GLM-5.3"),
            "thought": .string("high"), "followupMode": .string("queue"), "mode": .string("build"),
        ]
        object.merge(fields) { _, new in new }
        return try V4JSON.decode(SessionConfig.self, from: .object(object))
    }

    @Test func catalogueArriveApresLeSnapshot() throws {
        // Le catalogue n'est plus attendu avant l'abonnement : sans modèle dans la session, le défaut de l'hôte vient après.
        var settings = ComposerSettings.initial(config: nil, view: nil)
        settings.selectMode("yolo")
        #expect(settings.selection == nil)
        settings.adoptDefaultSelection(from: view)
        #expect(settings.selection == glm)
        #expect(settings.permissionMode == "yolo")                                       // le reste du brouillon est conservé
        settings.selectEffort("low")
        settings.adoptDefaultSelection(from: view)                                       // un choix existant n'est jamais écrasé
        #expect(settings.selection?.options?.reasoningLevel == "low")
    }

    @Test func initialiseDepuisLaSession() throws {
        let session = try config([
            "modelSelection": .object(["providerId": .string("account:zai-individual-coding-plan"),
                                       "modelId": .string("GLM-5.3-Flash"), "options": .object(["reasoningLevel": .string("low")])]),
            "mode": .string("yolo"), "planEnabled": .bool(true),
        ])
        let settings = ComposerSettings.initial(config: session, view: view)
        #expect(settings.selection?.modelId == "GLM-5.3-Flash")
        #expect(settings.permissionMode == "yolo")
        #expect(settings.planEnabled)
        #expect(settings.displayedMode == "plan")
        #expect(ComposerSettings.initial(config: nil, view: view).selection == glm)       // défaut de l'hôte
        let legacy = ComposerSettings.initial(config: try config(["mode": .string("plan")]), view: view)
        #expect(legacy.permissionMode == "build")                                        // « plan » ancien = build + plan
        #expect(legacy.planEnabled)
    }

    @Test func mistralToujoursAvecNone() throws {
        var settings = ComposerSettings(selection: glm)
        settings.selectModel(providerId: "new-provider", modelId: "mistral-large-4", in: view)
        #expect(settings.selection == ModelSelection(providerId: "new-provider", modelId: "mistral-large-4", reasoningLevel: "none"))
        let submission = try settings.submission(in: view).get()
        #expect(submission.modelSelection?.options?.reasoningLevel == "none")
        #expect(submission.mode == "build")
        #expect(submission.planEnabled == false)
    }

    @Test func niveauHorsListeRefuse() throws {
        var settings = ComposerSettings(selection: ModelSelection(providerId: "new-provider", modelId: "mistral-large-4", reasoningLevel: "high"))
        #expect(settings.submission(in: view) == .failure(.effortUnavailable("high")))
        settings.selectEffort("none")
        #expect(try settings.submission(in: view).get().modelSelection?.options?.reasoningLevel == "none")
        // Niveau absent (session restée sans niveau) : complété par le plus fort, comme ZCode le propose.
        let bare = ComposerSettings(selection: ModelSelection(providerId: "account:zai-individual-coding-plan", modelId: "GLM-5.3"))
        #expect(try bare.submission(in: view).get().modelSelection?.options?.reasoningLevel == "max")
        // Modèle retiré ou désactivé sur l'hôte : pas d'envoi.
        let gone = ComposerSettings(selection: ModelSelection(providerId: "new-provider", modelId: "mistral-ancien", reasoningLevel: "none"))
        #expect(gone.submission(in: view) == .failure(.modelUnavailable("mistral-ancien")))
        // Catalogue pas encore chargé : on envoie le choix tel quel (le serveur valide).
        #expect(try gone.submission(in: nil).get().modelSelection?.modelId == "mistral-ancien")
    }

    @Test func modesEtPlan() throws {
        var settings = ComposerSettings(selection: glm)
        settings.selectMode("guarded")
        #expect(settings.displayedMode == "guarded")
        settings.selectMode(ModeOption.plan)
        #expect(settings.displayedMode == "plan")
        let submission = try settings.submission(in: view).get()
        #expect(submission.mode == "guarded")                                            // jamais « plan »
        #expect(submission.planEnabled)
        settings.selectMode("yolo")
        #expect(settings.planEnabled == false)
        #expect(ModeOption.all.map(\.id) == ["build", "guarded", "plan", "yolo"])
        #expect(ModeOption.label(for: "edit") == "Modification automatique")
        #expect(ModeOption.label(for: "inconnu") == "inconnu")
    }

    @Test func choixConserveSiLaConfigNeChangePas() throws {
        let before = try config(["modelSelection": .object(["providerId": .string("account:zai-individual-coding-plan"),
                                                            "modelId": .string("GLM-5.3"), "options": .object(["reasoningLevel": .string("max")])])])
        var settings = ComposerSettings.initial(config: before, view: view)
        settings.selectModel(providerId: "new-provider", modelId: "mistral-large-4", in: view)
        settings.realign(from: before, to: before)                                         // trame suivante, config identique
        #expect(settings.selection?.modelId == "mistral-large-4")
        // La session change vraiment de modèle (tour démarré ailleurs, interface web) : on suit.
        let after = try config(["modelSelection": .object(["providerId": .string("account:zai-individual-coding-plan"),
                                                           "modelId": .string("GLM-5.3-Flash"), "options": .object(["reasoningLevel": .string("low")])]),
                                "mode": .string("guarded")])
        settings.realign(from: before, to: after)
        #expect(settings.selection?.modelId == "GLM-5.3-Flash")
        #expect(settings.permissionMode == "guarded")
    }

    @Test func libellesDEffort() {
        #expect(ChatLabels.effort("none") == "Désactivé")
        #expect(ChatLabels.effort("max") == "Maximal")
        #expect(ChatLabels.effort("xhigh") == "Très élevé")
        #expect(ChatLabels.effort("turbo") == "turbo")
    }

    @Test func modeDeCreationDUneSession() {
        #expect(ModeOption.sessionRequest(for: "plan") == SessionModeRequest(mode: "build", planEnabled: true))
        #expect(ModeOption.sessionRequest(for: "yolo") == SessionModeRequest(mode: "yolo", planEnabled: false))
        #expect(ModeOption.sessionRequest(for: "guarded") == SessionModeRequest(mode: "guarded", planEnabled: false))
        #expect(ModeOption.defaultModeNote(for: "yolo").contains("sans demander"))
        #expect(!ModeOption.defaultModeNote(for: "build").contains("sans demander"))
        #expect(ModeOption.defaultModeNote(for: nil) == "L'hôte applique son propre défaut.")
    }
}
