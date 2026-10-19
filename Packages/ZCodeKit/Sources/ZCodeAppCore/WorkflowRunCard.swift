import Foundation
import ZCodeV4
import ZCodeWire

/// Carte d'un run de workflow dans la conversation (lancé depuis l'app, ZCode Web ou `/workflow`) : statut, phases et
/// agents, jetons, questions en attente, résultat ou erreur.
public struct WorkflowRunCard: Equatable, Sendable, Identifiable {
    public struct Agent: Equatable, Sendable, Identifiable {
        /// Site de l'acteur dans le script : l'hôte identifie un acteur par `${siteId}@${ordinal}`.
        public let siteId: String?
        /// `actor.ordinal`, à défaut sa position dans `actors` (à partir de 1).
        public let ordinal: Int
        public let name: String
        public let status: WorkflowActorStatus
        /// Fil de l'agent (lecture seule, lot 13D) ; `nil` tant que l'hôte ne l'a pas créé.
        public let sessionId: String?
        /// `<siteId>@<ordinal>` (site vide s'il manque) : deux sites peuvent porter le même ordinal.
        public var id: String { "\(siteId ?? "")@\(ordinal)" }
    }

    public struct Phase: Equatable, Sendable, Identifiable {
        public let name: String
        public let isCurrent: Bool
        public let agents: [Agent]
        public var id: String { name }
    }

    public let runId: String
    /// `workflowLaunch.name` de la ligne de lancement, sinon `backgroundWorks.title`, sinon « Workflow ».
    public let name: String
    public let status: WorkflowRunStatus
    public let statusLabel: String
    /// « 2 phases · 1 agent au travail » ; jamais de compteur de phases nul, agents au travail seulement pendant un
    /// run en cours, même à 0 (« 1 phase » une fois fini, vide si rien).
    public let summary: String
    public let phases: [Phase]
    public let spentTokens: Int?
    public let questions: [WorkflowQuestion]
    /// Résultat livré au modèle : `originMeta.workflowNotification.result` du `turnHeader` `origin == "backgroundResult"`
    /// dont `originMeta.workId == runId` ; à défaut `run.resultPreview` (jamais produit en 3.15.1).
    public let resultPreview: String?
    public let error: String?
    /// `status == .running && !locked`.
    public let canStop: Bool
    /// Ligne de chronologie où placer la carte (ligne de lancement ou `anchorRowId`), `nil` : en tête de la conversation.
    public let anchorRowId: Int?
    /// `rowId` de la ligne `userInput` de lancement (`origin == "workflowLaunch"`) que la carte remplace : son texte
    /// est un message technique anglais de l'hôte (« Started the saved workflow… »).
    public let replacesRowId: Int?
    /// `rowId` du `turnHeader` de lancement du run (`origin == "workflowLaunch"`) : son pied de tour est retiré avec
    /// la question, le tour de lancement n'a plus rien de visible que la carte.
    let launchHeaderRowId: Int?

    public var id: String { runId }

    /// Identifiant d'entrée de la liste : négatif (FNV-1a 32 bits de `runId`, signe inversé, jamais 0), donc jamais
    /// égal à un `rowId` (≥ 0) et stable d'un état à l'autre.
    public var entryId: Int {
        var hash: UInt32 = 2_166_136_261
        for byte in runId.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash == 0 ? -1 : -Int(hash)
    }

    /// Phase des agents sans phase connue (placée à la fin).
    static let unphasedName = "Agents"

    /// Une carte par run, dans l'ordre des runs.
    public static func cards(runs: [WorkflowRun], works: [BackgroundWork], rows: [ConversationRow], locked: Bool)
        -> [WorkflowRunCard] {
        runs.map { run in
            let launch = launchRow(of: run.runId, in: rows)
            let work = works.first { $0.workId == run.runId }
            let name = nonEmpty(launch?.raw["workflowLaunch"]?["name"]?.stringValue)
                ?? nonEmpty(launchName(of: run.runId, in: rows))
                ?? nonEmpty(work?.title)
                ?? "Workflow"
            let (phases, phaseCount) = phases(of: run)
            return WorkflowRunCard(
                runId: run.runId, name: name, status: run.status, statusLabel: WorkflowLabels.runStatus(run.status),
                summary: summary(run: run, phaseCount: phaseCount), phases: phases, spentTokens: run.spentTokens,
                questions: run.pendingQuestions, resultPreview: result(of: run.runId, in: rows) ?? run.resultPreview,
                error: run.error, canStop: run.status == .running && !locked,
                anchorRowId: launch?.rowId ?? work?.anchorRowId, replacesRowId: launch?.rowId,
                launchHeaderRowId: rows.first { isLaunchHeader($0, runId: run.runId) }?.rowId)
        }
    }

    /// Ligne `userInput` de lancement du run : `origin == "workflowLaunch"` et `workflowLaunch.runId == runId`, ou à
    /// défaut de `workflowLaunch` sur elle, même `productTurnId` que le `turnHeader` de lancement du run.
    private static func launchRow(of runId: String, in rows: [ConversationRow]) -> ConversationRow? {
        let inputs = rows.filter { $0.kind == .userInput && $0.raw["origin"]?.stringValue == "workflowLaunch" }
        if let row = inputs.first(where: { $0.raw["workflowLaunch"]?["runId"]?.stringValue == runId }) { return row }
        guard let header = rows.first(where: { isLaunchHeader($0, runId: runId) }),
              let turn = header.raw["productTurnId"]?.stringValue else { return nil }
        return inputs.first { $0.raw["workflowLaunch"] == nil && $0.raw["productTurnId"]?.stringValue == turn }
    }

    /// Nom du `turnHeader` de lancement, quand la ligne `userInput` n'est pas chargée.
    private static func launchName(of runId: String, in rows: [ConversationRow]) -> String? {
        rows.first { isLaunchHeader($0, runId: runId) }?.raw["workflowLaunch"]?["name"]?.stringValue
    }

    private static func isLaunchHeader(_ row: ConversationRow, runId: String) -> Bool {
        row.kind == .turnHeader && row.raw["origin"]?.stringValue == "workflowLaunch"
            && row.raw["workflowLaunch"]?["runId"]?.stringValue == runId
    }

    private static func result(of runId: String, in rows: [ConversationRow]) -> String? {
        rows.last {
            $0.kind == .turnHeader && $0.raw["origin"]?.stringValue == "backgroundResult"
                && $0.raw["originMeta"]?["workId"]?.stringValue == runId
        }?.raw["originMeta"]?["workflowNotification"]?["result"]?.stringValue
    }

    /// Agents groupés par phase dans l'ordre de `phaseNames` ; une phase d'agent absente de `phaseNames` suit, dans
    /// l'ordre d'apparition ; les agents sans phase vont dans « Agents », à la fin. `count` : phases réelles, sans
    /// ce groupe.
    private static func phases(of run: WorkflowRun) -> (phases: [Phase], count: Int) {
        let agents = run.actors.enumerated().map { index, actor in
            let ordinal = actor.ordinal ?? index + 1
            return (phase: nonEmpty(actor.phaseName),
                    agent: Agent(siteId: actor.siteId, ordinal: ordinal, name: nonEmpty(actor.name) ?? "Agent \(ordinal)", status: actor.status,
                                 sessionId: actor.sessionId))
        }
        var names = run.phaseNames
        for case let name? in agents.map(\.phase) where !names.contains(name) { names.append(name) }
        var phases = names.map { name in
            Phase(name: name, isCurrent: name == run.currentPhase, agents: agents.filter { $0.phase == name }.map(\.agent))
        }
        let unphased = agents.filter { $0.phase == nil }.map(\.agent)
        if !unphased.isEmpty { phases.append(Phase(name: unphasedName, isCurrent: false, agents: unphased)) }
        return (phases, names.count)
    }

    /// Jamais de compteur de phases nul : phases réelles (sans le groupe « Agents ») si elles existent ; agents au travail
    /// (statut `running`) pendant un run en cours ou en attente seulement, même à 0. Vide si rien.
    private static func summary(run: WorkflowRun, phaseCount: Int) -> String {
        var parts: [String] = []
        if phaseCount > 0 { parts.append("\(phaseCount) \(phaseCount > 1 ? "phases" : "phase")") }
        if run.status == .running || run.status == .pending {
            let working = run.actors.filter { $0.status == .running }.count
            parts.append("\(working) \(working > 1 ? "agents" : "agent") au travail")
        }
        return parts.joined(separator: " · ")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
