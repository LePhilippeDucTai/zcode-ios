import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct InteractionFormsTests {
    struct UnexpectedPayload: Error {}

    func interaction(_ id: String) throws -> PendingInteraction {
        let list = try #require(Fixtures.file("synthetic/interactions-v3.15.1.json")["pendingInteractions"]?.arrayValue)
        return try #require(list.compactMap(PendingInteraction.init(json:)).first { $0.interactionId == id })
    }

    func userInput(_ id: String) throws -> UserInputRequest {
        guard case .userInput(let request) = try interaction(id).payload else { throw UnexpectedPayload() }
        return request
    }

    func permission(_ id: String) throws -> PermissionRequest {
        guard case .permission(let request) = try interaction(id).payload else { throw UnexpectedPayload() }
        return request
    }

    func styleForm() throws -> QuestionForm {
        QuestionForm(questions: try #require(try userInput("ask_style").questions))
    }

    @Test func choixMultipleEtReponseLibre() throws {
        var form = try styleForm()
        var finished = form.choose("Sobre")                       // choix simple : passe à la question suivante
        #expect(!finished)
        #expect(form.index == 1)
        finished = form.choose("Tarifs")                         // choix multiple : on reste sur la question
        #expect(!finished)
        finished = form.choose("FAQ")
        #expect(!finished)
        finished = form.choose("Tarifs")                         // décoché
        #expect(!finished)
        form.setCustom("  Blog ")
        #expect(form.isSelected("FAQ"))
        #expect(!form.isSelected("Tarifs"))
        #expect(form.answers(at: 1) == ["FAQ", "Blog"])
        #expect(form.content == [
            "answers": .object(["Quel style pour la page ?": .string("Sobre"), "Quelles sections ajouter ?": .string("FAQ, Blog")]),
            "answer_0": .string("Sobre"),
            "answer_1": .array([.string("FAQ"), .string("Blog")]),
        ])                                                           // deux questions : pas de clé `answer`
        #expect(form.answer.action == .accept)
    }

    @Test func questionsSansReponseOmises() throws {
        var form = try styleForm()
        form.next()
        form.setCustom("   ")
        #expect(form.isLast)
        #expect(form.content == ["answers": .object([:])])           // aucune chaîne vide inventée
        #expect(form.answer.json == .object(["action": .string("accept"), "content": .object(["answers": .object([:])])]))
    }

    @Test func reponseLibreRemplaceLeChoixSimple() throws {
        var form = try styleForm()
        _ = form.choose("Sobre")
        form.back()
        #expect(!form.canGoBack)
        form.setCustom("Minimaliste")
        #expect(!form.isSelected("Sobre"))
        #expect(form.answers(at: 0) == ["Minimaliste"])
        let finished = form.choose("Coloré")                     // le choix efface la réponse libre
        #expect(!finished)
        #expect(form.answers(at: 0) == ["Coloré"])
        #expect(form.index == 1)
    }

    @Test func derniereQuestionEnChoixSimpleEnvoie() throws {
        var form = QuestionForm(questions: try #require(try userInput("plan_1").questions))
        #expect(form.isLast)
        let finished = form.choose("approve")                    // dernière question : il faut envoyer
        #expect(finished)
        #expect(form.content == [
            "answers": .object(["Review this implementation plan.": .string("approve")]),
            "answer_0": .string("approve"), "answer": .string("approve"),
        ])
    }

    @Test func planApprouveOuAChanger() throws {
        let plan = try userInput("plan_1")
        #expect(PlanApproval.approve(plan) == InteractionAnswer(action: .accept, content: [
            "answers": .object(["Review this implementation plan.": .string("approve")]),
            "answer_0": .string("approve"), "answer": .string("approve"),
        ]))
        #expect(PlanApproval.requestChanges("  Ajoute des tests  ", to: plan)?.content?["answer"] == .string("Ajoute des tests"))
        #expect(PlanApproval.requestChanges("   ", to: plan) == nil)  // vide : ce serait un refus, pas une consigne
        #expect(InteractionAnswer.decline.json == .object(["action": .string("decline")]))
    }

    @Test func autorisationBoutonsEtConsigne() throws {
        let prompt = PermissionPrompt(try permission("perm_bash"))
        #expect(prompt.buttons.map(\.optionId) == ["allowOnce", "allowAlways", "deny"])
        #expect(prompt.feedbackOption?.optionId == "deny")
        #expect(prompt.answer(prompt.buttons[0]) == InteractionAnswer(optionId: "allowOnce"))
        #expect(prompt.answer(withFeedback: " Utilise la corbeille ") == InteractionAnswer(optionId: "deny", freeText: "Utilise la corbeille"))
        #expect(prompt.answer(withFeedback: "  \n ") == nil)
        let long = String(repeating: "é", count: 5_000)
        #expect(prompt.answer(withFeedback: long)?.freeText?.count == PermissionPrompt.maxFeedbackLength)
        #expect(prompt.detailText == "rm -rf dist")                  // une commande s'affiche telle quelle
        #expect(ChatLabels.permissionOption(prompt.buttons[1]) == "Toujours autoriser dans ce projet")
    }

    @Test func refusAvecLaConsigneTapee() throws {
        // Comme le web : la consigne déjà tapée accompagne le bouton « Refuser » (sinon elle serait perdue en silence).
        let prompt = PermissionPrompt(try permission("perm_bash"))
        let deny = try #require(prompt.buttons.first { $0.kind == .deny })
        #expect(prompt.answer(deny, feedback: " Utilise la corbeille ") == InteractionAnswer(optionId: "deny", freeText: "Utilise la corbeille"))
        #expect(prompt.answer(deny, feedback: "   ") == InteractionAnswer(optionId: "deny"))
        #expect(prompt.answer(prompt.buttons[0], feedback: "texte") == InteractionAnswer(optionId: "allowOnce"))   // autoriser : sans consigne
        // Avec « Affiner », la consigne part avec « Affiner » seulement : le refus reste nu.
        let refine = PermissionPrompt(try permission("perm_sub"))
        let subDeny = try #require(refine.buttons.first { $0.kind == .deny })
        #expect(refine.answer(subDeny, feedback: "change l'étape 2") == InteractionAnswer(optionId: "deny"))
    }

    @Test func optionInconnueTransmiseTelleQuelle() throws {
        let prompt = PermissionPrompt(try permission("perm_sub"))
        #expect(prompt.buttons.map(\.optionId) == ["allowOnce", "allowSession", "deny", "escalate"])   // « Refine » à part
        #expect(prompt.feedbackOption?.optionId == "workflowRefine")
        #expect(prompt.answer(prompt.buttons[3]).json == .object(["optionId": .string("escalate")]))
        #expect(prompt.buttons.map(ChatLabels.permissionOption)
            == ["Autoriser une fois", "Toujours autoriser dans cette session", "Refuser", "Escalate to admin"])
        #expect(prompt.detailText?.contains("\"steps\"") == true)    // détail non textuel : JSON lisible
        #expect(ChatLabels.origin(try interaction("perm_sub").origin) == "Demande du sous-agent explorer")
        #expect(ChatLabels.origin(nil) == nil)
    }

    /// Agent d'un run de workflow : `description` « persona (site@ordinal) » (tâche 0, `saved-workflows/agent/019`).
    /// En 3.15.1 l'hôte y joint `agentType: "zcode-workflow"`, qui garde la priorité (second cas).
    @Test func origineDUnAgentDeWorkflow() throws {
        let workflow = try V4JSON.decode(InteractionOrigin.self, from: .object([
            "kind": .string("subagent"), "description": .string("Rédacteur (actor#1@1)")]))
        #expect(ChatLabels.origin(workflow) == "Demande de l'agent Rédacteur (actor#1@1)")
        let typed = try V4JSON.decode(InteractionOrigin.self, from: .object([
            "kind": .string("subagent"), "agentType": .string("explorer"), "description": .string("x")]))
        #expect(ChatLabels.origin(typed) == "Demande du sous-agent explorer")
        let bare = try V4JSON.decode(InteractionOrigin.self, from: .object([
            "kind": .string("subagent"), "description": .string(" ")]))
        #expect(ChatLabels.origin(bare) == "Demande d'un sous-agent")
        // Marque d'un agent de workflow : la description l'emporte sur le type.
        let marked = try V4JSON.decode(InteractionOrigin.self, from: .object([
            "kind": .string("subagent"), "agentType": .string("zcode-workflow"), "description": .string("Rédacteur (actor#1@1)")]))
        #expect(ChatLabels.origin(marked) == "Demande de l'agent Rédacteur (actor#1@1)")
        let markedBare = try V4JSON.decode(InteractionOrigin.self, from: .object([
            "kind": .string("subagent"), "agentType": .string("zcode-workflow")]))
        #expect(ChatLabels.origin(markedBare) == "Demande du sous-agent zcode-workflow")
    }

    /// Demande réelle d'un agent de workflow (`saved-workflows/agent/019`, `agentType: "zcode-workflow"`).
    @Test func origineDUnAgentDeWorkflowRéelle() throws {
        let snapshot = try ConversationSnapshot(json: SavedWorkflowsFixtures.snapshot("state.agent.permission", in: "agent"))
        let interaction = try #require(snapshot.pendingInteractions.first)
        #expect(interaction.origin?.agentType == "zcode-workflow")
        #expect(ChatLabels.origin(interaction.origin) == "Demande de l'agent Rédacteur (actor#1@1)")
    }

    @Test func autorisationSansConsigne() throws {
        var json = try #require(try Fixtures.file("synthetic/interactions-v3.15.1.json")["pendingInteractions"]?.arrayValue?[0].objectValue)
        var payload = try #require(json["payload"]?.objectValue)
        payload["freeText"] = nil
        payload["detail"] = .object([:])
        json["payload"] = .object(payload)
        guard case .permission(let request) = try #require(PendingInteraction(json: .object(json))).payload else {
            throw UnexpectedPayload()
        }
        let prompt = PermissionPrompt(request)
        #expect(prompt.feedbackOption == nil)                        // l'hôte n'accepte pas de texte libre
        #expect(prompt.answer(withFeedback: "non") == nil)
        #expect(prompt.detailText == nil)
    }

    @Test func saisieSimple() throws {
        #expect(InteractionAnswer.text("  ma-clé  ") == InteractionAnswer(freeText: "ma-clé"))
        #expect(InteractionAnswer.text("   ") == nil)
        let choice = try V4JSON.decode(UserInputChoice.self, from: .object(["optionId": .string("oui"), "label": .string("Oui")]))
        #expect(InteractionAnswer.choice(choice) == InteractionAnswer(optionId: "oui"))
        #expect(ChatLabels.countdown(seconds: 42) == "L'agent continue seul dans 42 s")
    }
}
