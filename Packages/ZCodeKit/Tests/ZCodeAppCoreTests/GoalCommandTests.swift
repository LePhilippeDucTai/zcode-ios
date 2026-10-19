import Testing
import ZCodeAppCore

struct GoalCommandTests {
    @Test func analyseDesCommandesGoal() {
        #expect(GoalCommand.parse("/goal tests verts") == .set(objective: "tests verts"))
        #expect(GoalCommand.parse("/target  x ") == .set(objective: "x"))
        #expect(GoalCommand.parse("/goal replace corriger le build") == .set(objective: "corriger le build"))
        #expect(GoalCommand.parse("/goal\nligne 1\nligne 2") == .set(objective: "ligne 1\nligne 2"))
        #expect(GoalCommand.parse("/goal resume") == .resume)
        #expect(GoalCommand.parse("/goal pause") == .unsupported("pause"))
        #expect(GoalCommand.parse("/goal clear") == .unsupported("clear"))
        #expect(GoalCommand.parse("/goal show") == .unsupported("show"))
        // Comme le web (`slashCommands.ts`) : commande et premier mot sans tenir compte de la casse, premier mot = action.
        #expect(GoalCommand.parse("/goal resume le travail") == .resume)
        #expect(GoalCommand.parse("/goal Pause stp") == .unsupported("pause"))
        #expect(GoalCommand.parse("/Goal x") == .set(objective: "x") && GoalCommand.parse("/GOAL x") == .set(objective: "x"))
        #expect(GoalCommand.parse("/goal Replace corriger") == .set(objective: "corriger"))
        #expect(GoalCommand.parse("/goal replacer le moteur") == .set(objective: "replacer le moteur"))
        #expect(GoalCommand.parse("/goal") == .empty && GoalCommand.parse("/goal   ") == .empty)
        #expect(GoalCommand.parse("/goal replace") == .empty)
        #expect(GoalCommand.parse("/goalX") == nil && GoalCommand.parse("goal x") == nil)
        #expect(GoalCommand.parse("  /goal x") == nil)                       // `send` rogne le texte avant l'analyse
    }
}
