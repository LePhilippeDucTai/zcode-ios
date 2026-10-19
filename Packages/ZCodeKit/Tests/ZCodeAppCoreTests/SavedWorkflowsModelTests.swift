import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct SavedWorkflowsModelTests {
    /// Modèle de sessions démarré (index prêt) et modèle de workflows branchés sur `server`.
    func makeSavedWorkflows(_ server: FakeZCodeServer) async throws -> SavedWorkflowsModel {
        try await makeBoth(server).workflows
    }

    func makeBoth(_ server: FakeZCodeServer) async throws -> (workflows: SavedWorkflowsModel, sessions: SessionsModel) {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([server])))
        let sessions = SessionsModel(connection: connection, workspace: testWorkspacePath)
        await sessions.start()
        try await emitWhenListening(server, initialIndexFrame())
        _ = try await eventually { sessions.phase == .ready ? true : nil }
        let workflows = SavedWorkflowsModel(connection: connection, workspace: testWorkspacePath, sessions: sessions,
                                            builder: CommandBuilder(clientId: "client-test"))
        return (workflows, sessions)
    }

    @Test func barrièreFerméeMasqueLEntrée() async throws {
        let server = try await sessionsServer()
        await server.on("coding-plan-subscription.getDynamicWorkflowClientConfig") { _ in
            .object(["enabled": .bool(false), "mode": .string("disabled")])
        }
        let model = try await makeSavedWorkflows(server)
        #expect(model.available == nil)
        await model.checkAvailability()
        #expect(model.available == false)
    }

    @Test func barrièreOuverteLueUneSeuleFois() async throws {
        let server = try await sessionsServer()
        await server.on("coding-plan-subscription.getDynamicWorkflowClientConfig") { _ in
            .object(["enabled": .bool(true), "mode": .string("onDemand")])
        }
        let model = try await makeSavedWorkflows(server)
        await model.checkAvailability()
        await model.checkAvailability()
        #expect(model.available == true)
        #expect(await server.calls(to: "coding-plan-subscription.getDynamicWorkflowClientConfig").count == 1)
    }

    @Test func barrièreIllisibleVautFaux() async throws {
        let server = try await sessionsServer()
        await server.on("coding-plan-subscription.getDynamicWorkflowClientConfig") { _ in .string("x") }
        let model = try await makeSavedWorkflows(server)
        await model.checkAvailability()
        #expect(model.available == false)
    }

    @Test func deuxSectionsEtUneEnÉchec() async throws {
        let server = try await sessionsServer()
        let project = try #require(try Fixtures.records(in: "v3.15.1/saved-workflows/trivial").first { $0.name == "list.project" }).value
        await server.on("zcode-agent.listSavedWorkflows") { params in
            if params["scope"]?.stringValue == "global" { throw FakeRemoteError("EACCES: global illisible") }
            return project
        }
        let model = try await makeSavedWorkflows(server)
        await model.refresh()
        #expect(model.project?.workflows.contains { $0.name == "ios-probe" } == true)
        #expect(model.projectError == nil)
        #expect(model.global == nil)
        #expect(model.globalError == "Lecture impossible.")
        #expect(model.phase == .ready)
    }

    @Test func lesDeuxSectionsEnÉchecDonnentUnÉchec() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.listSavedWorkflows") { _ in throw FakeRemoteError("boum") }
        let model = try await makeSavedWorkflows(server)
        await model.refresh()
        guard case .failed = model.phase else { Issue.record("phase \(model.phase)"); return }
        #expect(model.projectError == "Lecture impossible." && model.globalError == "Lecture impossible.")
        #expect(model.phase == .failed("Lecture impossible."))
    }

    /// Libellé fixe d'une section en échec : panne de connexion ⇒ message de connexion ; sinon « Lecture impossible. ».
    @Test func libelléDUneLectureEnÉchec() {
        #expect(WorkflowLabels.listFailure(FakeRemoteError("EACCES")) == "Lecture impossible.")
        #expect(WorkflowLabels.listFailure(ConnectionFailure.unreachable("connexion fermée"))
            == ConnectionFailure.unreachable("connexion fermée").message)
        #expect(WorkflowLabels.listFailure(ConnectionFailure.unauthorized) == "Lecture impossible.")
    }

    /// Répond aux commandes selon leur type ; `start` : accusé de `startSavedWorkflow`.
    nonisolated static func answer(_ argument: JSONValue, start: (JSONValue) throws -> JSONValue,
                       create: ((JSONValue) -> JSONValue)? = nil, delete: ((JSONValue) -> JSONValue)? = nil) rethrows -> JSONValue {
        let envelope = argument["envelope"] ?? .null
        let commandId = envelope["commandId"] ?? .null
        switch envelope["type"]?.stringValue {
        case "createSession":
            if let create { return create(commandId) }
            return .object(["commandId": commandId, "status": .string("accepted"), "revisionAtDecision": .number(0),
                            "result": .object(["type": .string("createSession"), "sessionId": .string("sess_neuve")])])
        case "startSavedWorkflow":
            return try start(commandId)
        default:                                                  // deleteSession
            if let delete { return delete(commandId) }
            return .object(["commandId": commandId, "status": .string("accepted"), "revisionAtDecision": .number(0)])
        }
    }

    nonisolated static func refused(_ commandId: JSONValue) -> JSONValue {
        .object(["commandId": commandId, "status": .string("failed"), "revisionAtDecision": .number(0),
                 "reasonCode": .string("fault.command.savedWorkflowStartRejected.invalid_args"),
                 "message": .string("count: expected number")])
    }

    static let probe = SavedWorkflow(name: "ios-probe", description: "d", whenToUse: nil, scope: .project,
                                     path: "/w/.zcode/workflows/ios-probe.dwf.ts", args: [])

    func envelopes(_ server: FakeZCodeServer) async -> [JSONValue] {
        await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
    }

    @Test func lancementRéussi() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument) { commandId in
                .object(["commandId": commandId, "status": .string("accepted"), "revisionAtDecision": .number(1),
                         "result": .object(["type": .string("startSavedWorkflow"), "runId": .string("run_1"),
                                            "toolCallId": .string("launch-1")])])
            }
        }
        let model = try await makeSavedWorkflows(server)
        let outcome = await model.launch(Self.probe, args: ["count": .number(2)])
        #expect(outcome == .started(sessionId: "sess_neuve", runId: "run_1"))
        let sent = await envelopes(server)
        #expect(sent.map { $0["type"]?.stringValue } == ["createSession", "startSavedWorkflow"])
        #expect(sent[1]["sessionId"] == .string("sess_neuve"))
        #expect(sent[1]["payload"] == .object(["name": .string("ios-probe"), "scope": .string("project"),
                                               "args": .object(["count": .number(2)])]))
        #expect(model.launching == false)
    }

    @Test func refusSupprimeLaSession() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument) { Self.refused($0) }
        }
        let model = try await makeSavedWorkflows(server)
        let outcome = await model.launch(Self.probe, args: ["count": .string("abc")])
        #expect(outcome == .failed(message: "Arguments refusés par l'hôte.", detail: "count: expected number"))
        let sent = await envelopes(server)
        #expect(sent.map { $0["type"]?.stringValue } == ["createSession", "startSavedWorkflow", "deleteSession"])
        #expect(sent[2]["sessionId"] == .string("sess_neuve"))
    }

    @Test func exceptionSupprimeLaSession() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            try Self.answer(argument) { _ in throw FakeRemoteError("boum") }
        }
        let model = try await makeSavedWorkflows(server)
        let outcome = await model.launch(Self.probe, args: nil)
        guard case .failed(let message, let detail) = outcome else { Issue.record("issue \(outcome)"); return }
        #expect(message == "Le lancement a échoué.")
        #expect(detail?.isEmpty == false)
        let sent = await envelopes(server)
        #expect(sent.map { $0["type"]?.stringValue } == ["createSession", "startSavedWorkflow", "deleteSession"])
        #expect(model.launching == false)
    }

    @Test func brouillonRetiréAprèsRefus() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument) { Self.refused($0) }
        }
        let (model, sessions) = try await makeBoth(server)
        _ = await model.launch(Self.probe, args: nil)
        #expect(sessions.drafts.isEmpty)
    }

    @Test func brouillonRetiréMêmeSiLHôteRefuseLaSuppression() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument, start: { Self.refused($0) }, delete: { commandId in
                .object(["commandId": commandId, "status": .string("failed"), "revisionAtDecision": .number(0),
                         "reasonCode": .string("fault.command.deleteRejected")])
            })
        }
        let (model, sessions) = try await makeBoth(server)
        let outcome = await model.launch(Self.probe, args: nil)
        guard case .failed = outcome else { Issue.record("issue \(outcome)"); return }
        let sent = await envelopes(server)
        #expect(sent.last?["type"] == .string("deleteSession"))
        #expect(sessions.drafts.isEmpty)
    }

    @Test func créationRefusée() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument, start: { Self.refused($0) }, create: { commandId in
                .object(["commandId": commandId, "status": .string("failed"), "revisionAtDecision": .number(0),
                         "reasonCode": .string("fault.command.createRejected")])
            })
        }
        let model = try await makeSavedWorkflows(server)
        let outcome = await model.launch(Self.probe, args: nil)
        #expect(outcome == .failed(message: "Le lancement a échoué.",
                                   detail: "Création refusée par l'hôte (fault.command.createRejected)."))
        let sent = await envelopes(server)
        #expect(sent.map { $0["type"]?.stringValue } == ["createSession"])
        #expect(model.launching == false)
    }

    @Test func deuxLancementsConcurrentsUneSeuleSession() async throws {
        let server = try await sessionsServer()
        await server.on("zcode-agent.sendConversationCommandV4") { argument in
            Self.answer(argument) { commandId in
                .object(["commandId": commandId, "status": .string("accepted"), "revisionAtDecision": .number(1),
                         "result": .object(["type": .string("startSavedWorkflow"), "runId": .string("run_1")])])
            }
        }
        let model = try await makeSavedWorkflows(server)
        async let first = model.launch(Self.probe, args: nil)
        async let second = model.launch(Self.probe, args: nil)
        let outcomes = await [first, second]
        #expect(outcomes.contains(.started(sessionId: "sess_neuve", runId: "run_1")))
        #expect(outcomes.contains(.failed(message: "Un lancement est déjà en cours.", detail: nil)))
        let sent = await envelopes(server)
        #expect(sent.filter { $0["type"] == .string("createSession") }.count == 1)
        #expect(model.launching == false)
    }

    @Test func libellésDesRefus() {
        #expect(WorkflowLabels.startRefusal(reasonCode: "fault.command.savedWorkflowStartRejected.not_found", status: "rejected")
                == "Workflow introuvable ou illisible sur l'hôte.")
        #expect(WorkflowLabels.startRefusal(reasonCode: nil, status: "failed") == "Lancement refusé par l'hôte (failed).")
        #expect(WorkflowLabels.startRefusal(reasonCode: "fault.command.capabilityUnsupported", status: "failed")
                == "Cet hôte ne sait pas lancer de workflow enregistré.")
        #expect(WorkflowLabels.startRefusal(reasonCode: "x.y", status: "failed") == "Lancement refusé par l'hôte (x.y).")
        #expect(WorkflowLabels.cancelRefusal(reasonCode: "fault.command.backgroundWorkCancelRejected.not_running")
                == "Ce run est déjà terminé.")
        #expect(WorkflowLabels.cancelRefusal(reasonCode: nil) == "Arrêt refusé par l'hôte.")
        #expect(WorkflowLabels.emptySection(dir: nil) == "Aucun workflow.")
        #expect(WorkflowLabels.emptySection(dir: "/w/.zcode/workflows") == "Aucun workflow. Dossier sur l'hôte : /w/.zcode/workflows")
    }
}
