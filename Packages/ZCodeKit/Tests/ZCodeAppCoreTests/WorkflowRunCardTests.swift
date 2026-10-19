import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// États réels de la sonde des workflows enregistrés (tâche 0) rendus lisibles par `ConversationSnapshot(json:)`.
enum SavedWorkflowsFixtures {
    /// État `name` du dossier, complété d'une identité factice si elle manque (`state.agent.*`) et de la fenêtre de
    /// lignes `rows.trivial.final` du même dossier (vide si le dossier n'en a pas) : les états émis n'ont pas de `rows`.
    static func snapshot(_ name: String, in folder: String = "trivial") throws -> JSONValue {
        let records = try Fixtures.records(in: "v3.15.1/saved-workflows/\(folder)")
        guard let record = records.last(where: { $0.name == name }) else {
            throw FixtureError.noRecord(folder: folder, prefix: name)
        }
        let window = records.last { $0.name == "rows.trivial.final" }?.value.arrayValue ?? []
        var object = record.value.objectValue ?? [:]
        object["rows"] = .object(["window": .array(window), "totalCount": .number(Double(window.count))])
        object["sessionId"] = object["sessionId"] ?? .string("sess_x")
        object["logEpoch"] = object["logEpoch"] ?? .string("e")
        return .object(object)
    }
}

@MainActor
struct WorkflowRunCardTests {
    func run(_ id: String, _ status: String, _ fields: [String: JSONValue] = [:]) throws -> WorkflowRun {
        var object = fields
        object["runId"] = .string(id)
        object["status"] = .string(status)
        return try #require(WorkflowRun(json: .object(object)))
    }

    func work(_ id: String, title: String? = nil, anchorRowId: Int? = nil) throws -> BackgroundWork {
        var object: [String: JSONValue] = ["workId": .string(id), "kind": .string("workflow"), "status": .string("running")]
        if let title { object["title"] = .string(title) }
        if let anchorRowId { object["anchorRowId"] = .number(Double(anchorRowId)) }
        return try V4JSON.decode(BackgroundWork.self, from: .object(object))
    }

    func row(_ rowId: Int, _ kind: String, turn: String, _ fields: [String: JSONValue] = [:]) throws -> ConversationRow {
        var object = fields
        object["rowId"] = .number(Double(rowId))
        object["kind"] = .string(kind)
        object["turnId"] = .string(turn)
        return try #require(ConversationRow(json: .object(object)))
    }

    /// Trois questions de tours distincts : entrées d'ids [1, 2, 3].
    func threeEntries() throws -> [ChatEntry] {
        let rows = try (1...3).map { try row($0, "userInput", turn: "t\($0)", ["text": .string("q\($0)")]) }
        let entries = ChatTimeline.entries(from: rows)
        #expect(entries.map(\.id) == [1, 2, 3])
        return entries
    }

    func card(_ runId: String, anchor: Int?) throws -> WorkflowRunCard {
        try #require(WorkflowRunCard.cards(runs: [run(runId, "running")], works: [work(runId, anchorRowId: anchor)],
                                           rows: [], locked: false).first)
    }

    func cards(in entries: [ChatEntry]) -> [WorkflowRunCard] {
        entries.compactMap { if case .workflowRun(let card) = $0.content { card } else { nil } }
    }

    @Test func runTerminéDepuisLaFixture() throws {
        let snapshot = try ConversationSnapshot(json: SavedWorkflowsFixtures.snapshot("state.trivial.final"))
        let cards = WorkflowRunCard.cards(runs: snapshot.workflowRuns, works: snapshot.backgroundWorks, rows: snapshot.rows, locked: false)
        let card = try #require(cards.last)
        #expect(card.status == .completed && card.statusLabel == "Terminé" && !card.canStop)
        #expect(card.name == "ios-probe")
        #expect(card.resultPreview == "bonjour monde ×2")
        #expect(card.anchorRowId == 2 && card.replacesRowId == 2)
        #expect(card.summary.isEmpty)                                  // run trivial terminé : aucun compteur nul
    }

    /// Le tour de lancement n'a plus rien de visible : la carte prend la place de sa question et de son pied.
    @Test func carteRemplaceLeTourDeLancementDeLaFixture() throws {
        let snapshot = try ConversationSnapshot(json: SavedWorkflowsFixtures.snapshot("state.trivial.final"))
        let base = ChatTimeline.entries(from: snapshot.rows)
        #expect(base.contains { if case .turnFooter = $0.content { $0.id == 1 } else { false } })   // pied du lancement
        let card = try #require(WorkflowRunCard.cards(runs: snapshot.workflowRuns, works: snapshot.backgroundWorks,
                                                      rows: snapshot.rows, locked: false).last)
        let entries = ChatTimeline.inserting([card], into: base)
        #expect(!entries.contains { $0.id == 1 || $0.id == 2 })
        let first = try #require(entries.first)
        #expect(first.id == card.entryId && first.startsTurn)          // reprend l'ouverture de tour de la question
        #expect(entries.map(\.id) == [card.entryId] + base.map(\.id).filter { $0 > 2 })
    }

    @Test func nomDeRepli() {
        let run = WorkflowRun(json: .object(["runId": .string("r"), "status": .string("running")]))!
        let cards = WorkflowRunCard.cards(runs: [run], works: [], rows: [], locked: false)
        #expect(cards[0].name == "Workflow" && cards[0].anchorRowId == nil)
    }

    @Test func nomDepuisBackgroundWorks() throws {
        let cards = try WorkflowRunCard.cards(runs: [run("r", "running")], works: [work("r", title: "ios-probe")], rows: [],
                                              locked: false)
        #expect(cards[0].name == "ios-probe")
        #expect(cards[0].replacesRowId == nil && cards[0].resultPreview == nil)
    }

    @Test func arrêterSeulementEnCours() throws {
        let runs = try ["running", "completed", "stopped", "errored"].map { try run($0, $0) }
        let cards = WorkflowRunCard.cards(runs: runs, works: [], rows: [], locked: false)
        #expect(cards.map(\.canStop) == [true, false, false, false])
        #expect(cards.map(\.statusLabel) == ["En cours", "Terminé", "Arrêté", "Erreur"])
    }

    @Test func pasDArrêterEnLectureSeule() throws {
        let cards = try WorkflowRunCard.cards(runs: [run("r", "running")], works: [], rows: [], locked: true)
        #expect(cards[0].status == .running && !cards[0].canStop)
    }

    @Test func unCarteParRun() throws {
        let runs = try ["a", "b", "c"].map { try run($0, "running") }
        let cards = WorkflowRunCard.cards(runs: runs, works: [], rows: [], locked: false)
        #expect(cards.map(\.runId) == ["a", "b", "c"])
        #expect(Set(cards.map(\.entryId)).count == 3)
        #expect(cards.allSatisfy { $0.entryId < 0 })
    }

    @Test func phasesEtAgents() throws {
        let actors: JSONValue = .array([
            .object(["ordinal": .number(1), "name": .string("A"), "status": .string("running"), "phaseName": .string("P1")]),
            .object(["ordinal": .number(2), "status": .string("waiting"), "phaseName": .string("P2")]),
        ])
        let value = try run("r", "running", ["actors": actors, "phaseNames": .array([.string("P1"), .string("P2")]),
                                              "currentPhase": .string("P1")])
        let card = try #require(WorkflowRunCard.cards(runs: [value], works: [], rows: [], locked: false).first)
        #expect(card.phases.map(\.name) == ["P1", "P2"])
        #expect(card.phases[0].isCurrent && !card.phases[1].isCurrent)
        #expect(card.phases[0].agents.map(\.name) == ["A"])
        #expect(card.phases[1].agents[0].name == "Agent 2")
        #expect(card.summary == "2 phases · 1 agent au travail")
    }

    @Test func agentsSansPhaseALaFin() throws {
        let actors: JSONValue = .array([
            .object(["ordinal": .number(1), "status": .string("running")]),
            .object(["ordinal": .number(2), "status": .string("running"), "phaseName": .string("P1")]),
        ])
        let value = try run("r", "running", ["actors": actors, "phaseNames": .array([.string("P1")])])
        let card = try #require(WorkflowRunCard.cards(runs: [value], works: [], rows: [], locked: false).first)
        #expect(card.phases.map(\.name) == ["P1", "Agents"])
        #expect(card.phases[1].agents.map(\.ordinal) == [1])
        #expect(card.summary == "1 phase · 2 agents au travail")
    }

    /// L'hôte identifie un acteur par `${siteId}@${ordinal}` : deux sites de même ordinal donnent deux pastilles.
    @Test func identitéDAgentParSiteEtOrdinal() throws {
        let actors: JSONValue = .array([
            .object(["siteId": .string("s1"), "ordinal": .number(1), "name": .string("A"), "status": .string("running")]),
            .object(["siteId": .string("s2"), "ordinal": .number(1), "name": .string("B"), "status": .string("running")]),
            .object(["status": .string("waiting")]),
        ])
        let value = try run("r", "running", ["actors": actors])
        let card = try #require(WorkflowRunCard.cards(runs: [value], works: [], rows: [], locked: false).first)
        let agents = card.phases.flatMap(\.agents)
        #expect(agents.map(\.id) == ["s1@1", "s2@1", "@3"])
        #expect(Set(agents.map(\.id)).count == 3)
    }

    @Test func résuméSansCompteurNul() throws {
        let phases: JSONValue = .array([.string("P1")])
        func summary(_ status: String, _ fields: [String: JSONValue] = [:]) throws -> String {
            try #require(WorkflowRunCard.cards(runs: [run("r", status, fields)], works: [], rows: [], locked: false).first).summary
        }
        #expect(try summary("running") == "0 agent au travail")
        #expect(try summary("pending", ["phaseNames": phases]) == "1 phase · 0 agent au travail")
        #expect(try summary("completed", ["phaseNames": phases]) == "1 phase")
        #expect(try summary("completed") == "")
        #expect(try summary("stopped") == "" && summary("errored") == "")
    }

    @Test func activitéDansLaListe() {
        #expect(WorkflowLabels.activity(nil) == nil)
        #expect(WorkflowLabels.activity([]) == nil)
        func activity(_ status: String, phase: String? = nil) -> WorkflowActivity {
            var object: [String: JSONValue] = ["runId": .string("r"), "status": .string(status)]
            if let phase { object["currentPhase"] = .string(phase) }
            return try! V4JSON.decode(WorkflowActivity.self, from: .object(object))
        }
        #expect(WorkflowLabels.activity([activity("running", phase: "Écriture")]) == "Workflow : Écriture")
        #expect(WorkflowLabels.activity([activity("pending")]) == "Workflow en cours")
        #expect(WorkflowLabels.activity([activity("completed")]) == "Workflow terminé")
        #expect(WorkflowLabels.activity([activity("stopped")]) == "Workflow arrêté")
        #expect(WorkflowLabels.activity([activity("errored")]) == "Workflow en erreur")
        // Dernier run seulement.
        #expect(WorkflowLabels.activity([activity("completed"), activity("running", phase: "P")]) == "Workflow : P")
    }

    @Test func arrêterEnvoieCancelBackgroundWork() async throws {
        let server = try await conversationServer()
        let model = try await readyConversation(server) {
            $0["workflowRuns"] = .object(["revision": .number(1), "runs": .array([
                .object(["runId": .string("run_1"), "status": .string("running")])])])
        }
        #expect(model.workflowCards.map(\.runId) == ["run_1"])
        #expect(model.entries.first?.id == model.workflowCards[0].entryId)       // sans ancre : en tête
        await model.cancelWorkflowRun("run_1")
        let envelopes = await server.calls(to: "zcode-agent.sendConversationCommandV4").compactMap { $0["envelope"] }
        let cancel = try #require(envelopes.last)
        #expect(cancel["type"] == .string("cancelBackgroundWork"))
        #expect(cancel["payload"] == .object(["workId": .string("run_1")]))
        #expect(model.commandError == nil)
    }

    @Test func carteAncréeAprèsSaLigne() throws {
        let card = try card("r", anchor: 2)
        let entries = ChatTimeline.inserting([card], into: try threeEntries())
        #expect(entries.map(\.id) == [1, 2, card.entryId, 3])
        #expect(cards(in: entries) == [card])
        #expect(entries[2].startsTurn == false && entries[2].messageTime == nil && entries[2].fileChangesTarget == nil)
    }

    @Test func carteSansAncreEnTête() throws {
        for anchor in [nil, 99] {
            let card = try card("r", anchor: anchor)
            let entries = ChatTimeline.inserting([card], into: try threeEntries())
            #expect(entries.map(\.id) == [card.entryId, 1, 2, 3])
        }
    }

    @Test func carteRemplaceLaLigneDeLancement() throws {
        let launch: JSONValue = .object(["name": .string("ios-probe"), "runId": .string("r")])
        let rows = try [
            row(1, "userInput", turn: "t1", ["text": .string("q1")]),
            row(2, "userInput", turn: "t2", ["text": .string("Started the saved workflow…"),
                                             "origin": .string("workflowLaunch"), "workflowLaunch": launch]),
            row(3, "userInput", turn: "t3", ["text": .string("q3")]),
        ]
        let card = try #require(WorkflowRunCard.cards(runs: [run("r", "running")], works: [work("r", anchorRowId: 1)],
                                                      rows: rows, locked: false).first)
        #expect(card.anchorRowId == 2 && card.replacesRowId == 2 && card.name == "ios-probe")
        let entries = ChatTimeline.inserting([card], into: ChatTimeline.entries(from: rows))
        #expect(entries.map(\.id) == [1, card.entryId, 3])
        #expect(entries[1].startsTurn)                                 // reprise de la question remplacée
    }

    @Test func huitRunsSansDoublon() throws {
        let runs = try (1...8).map { try run("run_\($0)", "running") }
        let works = try (1...8).map { try work("run_\($0)", anchorRowId: $0 % 2 == 0 ? 2 : nil) }
        let cards = WorkflowRunCard.cards(runs: runs, works: works, rows: [], locked: false)
        let base = try threeEntries()
        let once = ChatTimeline.inserting(cards, into: base)
        let twice = ChatTimeline.inserting(cards, into: once)
        #expect(twice == once)
        #expect(self.cards(in: twice).count == 8)
        #expect(Set(twice.map(\.id)).count == twice.count)
        #expect(twice.map(\.id).filter { $0 >= 0 } == [1, 2, 3])
    }

    @Test func refusDArrêtTraduit() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") {
            ack($0["envelope"] ?? .null, status: "rejected", reason: "fault.command.backgroundWorkCancelRejected.not_running")
        }
        let model = try await readyConversation(server) {
            $0["workflowRuns"] = .object(["revision": .number(1), "runs": .array([
                .object(["runId": .string("run_1"), "status": .string("running")])])])
        }
        await model.cancelWorkflowRun("run_1")
        #expect(model.commandError == "Ce run est déjà terminé.")
    }
}
