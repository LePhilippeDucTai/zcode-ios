import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct SavedWorkflowsDecodingTests {
    static let trivial = "v3.15.1/saved-workflows/trivial"
    static let agent = "v3.15.1/saved-workflows/agent"
    static let agentCancel = "v3.15.1/saved-workflows/agent-cancel"

    static func value(_ folder: String, _ name: String) throws -> JSONValue {
        guard let record = try Fixtures.records(in: folder).last(where: { $0.name == name }) else {
            throw FixtureError.noRecord(folder: folder, prefix: name)
        }
        return record.value
    }

    @Test func listeDuProjetAvecInvalide() throws {
        let list = try SavedWorkflowList(json: Self.value(Self.trivial, "list.project"))
        let probe = try #require(list.workflows.first { $0.name == "ios-probe" })
        #expect(probe.scope == .project)
        #expect(probe.description == "Sonde iOS triviale")
        #expect(probe.args.map(\.name) == ["count", "who"])
        #expect(probe.args[0].type == .number && probe.args[0].required)
        #expect(probe.args[1].type == .string && probe.args[1].defaultValue == .string("monde") && !probe.args[1].required)
        #expect(list.invalid.contains { $0.path.hasSuffix("ios-probe-invalide.dwf.ts") && !$0.reason.isEmpty })
        #expect(list.dir?.hasSuffix(".zcode/workflows") == true)
    }

    @Test func listeGlobaleLisible() throws {
        let list = try SavedWorkflowList(json: Self.value(Self.trivial, "list.global"))
        #expect(list.workflows.allSatisfy { $0.scope == .global })
    }

    @Test func argInconnuOuTypeInconnuGardé() throws {
        let json = try JSONValue.decode(Data(#"{"workflows":[{"name":"x","description":"d","scope":"project","path":"/p","args":{"a":{"type":"date"}}}],"invalid":[]}"#.utf8))
        let list = try SavedWorkflowList(json: json)
        #expect(list.workflows[0].args[0].type.rawValue == "date")
    }

    @Test func runTerminé() throws {
        let state = try Self.value(Self.trivial, "state.trivial.final")
        let snapshot = try ConversationSnapshot(json: Self.withEmptyRows(state))
        let run = try #require(snapshot.workflowRuns.last)
        #expect(run.status == .completed)
        #expect(run.resultPreview == nil)          // jamais produit par l'hôte 3.15.1 (tâche 0)
        #expect(run.spentTokens == 0)
        #expect(run.toolCallId?.hasPrefix("launch-") == true)
        let work = try #require(snapshot.backgroundWorks.last)
        #expect(work.kind == "workflow" && work.status == .resultPending && work.workId == run.runId)
        #expect(work.cancellable == false)
    }

    @Test func runAvecAgentEnCours() throws {
        let state = try Self.value(Self.agent, "state.agent.afterResubscribe")
        let snapshot = try ConversationSnapshot(json: Self.withIdentity(state))
        let run = try #require(snapshot.workflowRuns.last)
        #expect(run.status == .running)
        #expect(run.currentPhase == "Écriture" && run.phaseNames == ["Écriture"])
        let actor = try #require(run.actors.first)
        #expect(actor.name == "Rédacteur" && actor.ordinal == 1 && actor.siteId == "actor#1")
        #expect(actor.status == .running && actor.phaseName == "Écriture")
        #expect(snapshot.backgroundWorks.last?.status == .running)
        #expect(snapshot.backgroundWorks.last?.cancellable == true)
    }

    @Test func runArrêté() throws {
        let state = try Self.value(Self.agentCancel, "state.agent.final")
        let snapshot = try ConversationSnapshot(json: Self.withEmptyRows(state))
        let run = try #require(snapshot.workflowRuns.last)
        #expect(run.status == .stopped && run.stopReason == "user")
        #expect(snapshot.backgroundWorks.last?.status == .cancelled)
    }

    @Test func runIllisibleIgnoré() throws {
        var state = try Self.value(Self.trivial, "state.trivial.final").objectValue ?? [:]
        state["workflowRuns"] = .object(["revision": .number(1), "runs": .array([.object(["status": .string("running")])])])
        let snapshot = try ConversationSnapshot(json: Self.withEmptyRows(.object(state)))
        #expect(snapshot.workflowRuns.isEmpty)
    }

    @Test func erreurEnTexteOuEnObjet() throws {
        let text = try #require(WorkflowRun(json: .object(["runId": .string("r"), "status": .string("errored"), "error": .string("boum")])))
        #expect(text.error == "boum")
        let object = try #require(WorkflowRun(json: .object(["runId": .string("r"), "status": .string("errored"),
                                                              "error": .object(["message": .string("pan")])])))
        #expect(object.error == "pan")
    }

    @Test func permissionDUnAgent() throws {
        let state = try Self.value(Self.agent, "state.agent.permission")
        let snapshot = try ConversationSnapshot(json: Self.withIdentity(state))
        let interaction = try #require(snapshot.pendingInteractions.first)
        #expect(interaction.origin?.kind == "subagent")
        #expect(interaction.origin?.description == "Rédacteur (actor#1@1)")
    }

    @Test func activitéDansLIndex() throws {
        let summary = try V4JSON.decode(SessionSummary.self, from: Self.value(Self.trivial, "index.trivial"))
        #expect(summary.workflowActivity?.runs.isEmpty == false)
    }

    @Test func activitéAvecPhases() throws {
        let summary = try V4JSON.decode(SessionSummary.self, from: Self.value(Self.agent, "index.agent"))
        let run = try #require(summary.workflowActivity?.runs.first)
        #expect(run.name == "ios-probe-agent" && run.status == .completed)
        #expect(run.phases?.map(\.name) == ["Écriture"] && run.phases?.map(\.status) == [.done])
        #expect(run.currentPhase == "Écriture" && run.agentsWorking == 0)
    }

    @Test func activitéIllisibleNeFaitPasPerdreLeRésumé() throws {
        var object = try Self.value(Self.trivial, "index.trivial").objectValue ?? [:]
        object["workflowActivity"] = .string("cassé")
        let summary = try V4JSON.decode(SessionSummary.self, from: .object(object))
        #expect(summary.workflowActivity == nil)
        #expect(summary.title == "ios-probe")
    }

    @Test func allerRetourHorsLigne() throws {
        let summary = try V4JSON.decode(SessionSummary.self, from: Self.value(Self.trivial, "index.trivial"))
        let back = try V4JSON.decode(SessionSummary.self, from: V4JSON.encode(summary))
        #expect(back == summary)
    }

    @Test func commandes() throws {
        let builder = CommandBuilder(clientId: "c")
        let start = builder.startSavedWorkflow(sessionId: "s", name: "ios-probe", scope: .project, args: ["count": .number(2)])
        #expect(start.type == .startSavedWorkflow && start.baseRevision == nil)
        #expect(start.payload == .object(["name": .string("ios-probe"), "scope": .string("project"),
                                          "args": .object(["count": .number(2)])]))
        let bare = builder.startSavedWorkflow(sessionId: "s", name: "x", scope: nil, args: nil)
        #expect(bare.payload == .object(["name": .string("x")]))
        let empty = builder.startSavedWorkflow(sessionId: "s", name: "x", scope: nil, args: [:])
        #expect(empty.payload == .object(["name": .string("x")]))
        let cancel = builder.cancelBackgroundWork(sessionId: "s", workId: "run_1")
        #expect(cancel.type == .cancelBackgroundWork)
        #expect(cancel.payload == .object(["workId": .string("run_1")]))
    }

    /// Les états émis par la sonde n'ont pas de `rows` : fenêtre vide pour `ConversationSnapshot.init(json:)`.
    static func withEmptyRows(_ state: JSONValue) -> JSONValue {
        var object = state.objectValue ?? [:]
        object["rows"] = .object(["window": .array([]), "totalCount": .number(0)])
        return .object(object)
    }

    /// Certaines vues de la sonde (`state.agent.*`) n'ont ni identité ni `rows` : on les complète.
    static func withIdentity(_ state: JSONValue) -> JSONValue {
        var object = withEmptyRows(state).objectValue ?? [:]
        object["sessionId"] = object["sessionId"] ?? .string("sess_x")
        object["logEpoch"] = object["logEpoch"] ?? .string("e")
        return .object(object)
    }
}
