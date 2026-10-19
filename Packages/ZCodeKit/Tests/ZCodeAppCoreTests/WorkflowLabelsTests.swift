import Testing
import ZCodeV4
import ZCodeAppCore

@Suite struct WorkflowLabelsTests {
    @Test func libellesDeStatutDAgent() {
        #expect(WorkflowLabels.actorStatus(.waiting) == "En attente")
        #expect(WorkflowLabels.actorStatus(.running) == "Au travail")
        #expect(WorkflowLabels.actorStatus(.completed) == "Terminé")
        #expect(WorkflowLabels.actorStatus(WorkflowActorStatus(rawValue: "weird")) == "weird")
    }
}
