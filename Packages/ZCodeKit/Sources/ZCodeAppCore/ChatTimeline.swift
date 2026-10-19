import Foundation
import ZCodeV4
import ZCodeWire

/// Élément affichable d'une conversation.
public enum ChatItem: Identifiable, Equatable, Sendable {
    case user(rowId: Int, UserInput)
    case assistant(rowId: Int, AssistantText)
    case reasoning(rowId: Int, Reasoning)
    case tool(rowId: Int, ToolCall, subagent: SubagentLink?)
    case subagent(rowId: Int, Subagent)
    /// Séparateur de chronologie (compactage, changement de modèle, Goal…).
    case marker(rowId: Int, label: String)
    /// Type inconnu de cette version de l'app, ou ligne mal formée : carte générique avec le JSON.
    case unsupported(rowId: Int, kind: String, json: JSONValue)

    public var id: Int {
        switch self {
        case .user(let id, _), .assistant(let id, _), .reasoning(let id, _), .tool(let id, _, _), .subagent(let id, _),
             .marker(let id, _), .unsupported(let id, _, _):
            id
        }
    }

    /// Carte d'outil ou réflexion : ce qu'un groupe peut replier (lot 13I).
    var isToolOrReasoning: Bool {
        switch self {
        case .tool, .reasoning: true
        default: false
        }
    }
}

/// Une cellule de la liste : un élément visible, ou le pied d'un tour (résumé, fichiers modifiés).
///
/// La liste est à plat (une cellule par entrée) pour que le défilement se fasse au niveau des éléments : un tour réel
/// dépasse souvent la fenêtre chargée, et un delta ne doit réévaluer que sa propre cellule.
public struct ChatEntry: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case item(ChatItem)
        /// Pied d'un tour : seul un état connu (`summaryLabel != nil`) en produit un.
        case turnFooter(TurnHeader)
        /// Carte d'un run de workflow (`WorkflowRunCard`), placée par `ChatTimeline.inserting`.
        case workflowRun(WorkflowRunCard)
        /// Cartes d'outils et réflexions consécutives repliées en une ligne (lot 13I), produite par `ChatTimeline.grouping`.
        case toolGroup(ToolGroup)
    }

    /// `rowId` de l'élément, ou de la ligne d'en-tête pour un pied. Dérivé des lignes du serveur, jamais de l'ordre
    /// d'apparition : charger une page plus ancienne ou appliquer un delta ne change l'identifiant d'aucune entrée.
    public let id: Int
    /// Première entrée d'un groupe de lignes contiguës d'un même tour (espacement plus large avant elle).
    public let startsTurn: Bool
    public let content: Content
    /// Pied d'un tour qui a modifié des fichiers : cible de `ConversationModel.fileChanges(for:)` (l'en-tête du tour,
    /// comme `ConversationFileSummaryPanel.tsx`). `nil` pour un élément, un tour sans fichier ou un en-tête sans `entityId`.
    public let fileChangesTarget: RowTarget?
    /// Heure de la ligne (ms, `createdAt` de l'hôte) pour l'étiquette « il y a … » : seulement sur une question et
    /// sur la dernière réponse de chaque tour (lot 13F). `nil` ailleurs, et quand l'hôte n'a pas daté la ligne.
    public let messageTime: Double?

    func withStartsTurn(_ value: Bool) -> ChatEntry {
        ChatEntry(id: id, startsTurn: value, content: content, fileChangesTarget: fileChangesTarget, messageTime: messageTime)
    }
}

/// Lignes du serveur → entrées affichables (règles de l'interface web de ZCode).
public enum ChatTimeline {
    public static func entries(from rows: [ConversationRow]) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        var currentId: String?
        var header: (row: ConversationRow, value: TurnHeader)?
        var group: [ChatEntry] = []
        // Dernière réponse de chaque tour (par `turnId` sur toutes les lignes) : seule à porter l'heure (lot 13F).
        var lastAnswer: [String: Int] = [:]
        let pairs = subagentPairs(rows)
        for row in rows where row.kind == .assistantText { lastAnswer[row.turnId ?? "row-\(row.rowId)"] = row.rowId }

        // Un groupe = lignes contiguës de même `turnId` (un `turnId` peut reparaître plus loin : nouveau groupe).
        func flush() {
            if let header, header.value.summaryLabel != nil {
                let target = (header.value.fileChanges?.files ?? 0) > 0 ? RowTarget(row: header.row) : nil
                group.append(ChatEntry(id: header.row.rowId, startsTurn: group.isEmpty, content: .turnFooter(header.value),
                                       fileChangesTarget: target, messageTime: nil))
            }
            entries += group
            header = nil
            group = []
        }

        for row in rows {
            let turnId = row.turnId ?? "row-\(row.rowId)"
            if turnId != currentId {
                flush()
                currentId = turnId
            }
            if case .turnHeader(let value) = row.content {
                header = (row, value)
            } else if pairs.claimed.contains(row.rowId) {
                continue                                         // ligne `subagent` portée par sa carte
            } else if let item = item(for: row, link: pairs.byTool[row.rowId]) {
                let timed = row.kind == .userInput || lastAnswer[turnId] == row.rowId
                group.append(ChatEntry(id: row.rowId, startsTurn: group.isEmpty, content: .item(item), fileChangesTarget: nil,
                                       messageTime: timed ? row.createdAt : nil))
            }
        }
        flush()
        return entries
    }

    /// Insère chaque carte juste après l'entrée dont l'id vaut `anchorRowId` ; carte sans ancre, ou ancre absente des
    /// entrées chargées : en tête, dans l'ordre des runs. L'entrée dont l'id vaut `replacesRowId` d'une carte est
    /// retirée et la carte prend sa place (et son `startsTurn`) ; le pied du tour de lancement est retiré aussi. Les cartes déjà présentes dans `entries` sont d'abord retirées : appliquer
    /// deux fois la même insertion ne duplique rien.
    public static func inserting(_ cards: [WorkflowRunCard], into entries: [ChatEntry]) -> [ChatEntry] {
        let launchFooters = Set(cards.compactMap(\.launchHeaderRowId))
        let base = entries.filter {
            switch $0.content {
            case .workflowRun: false
            case .turnFooter: !launchFooters.contains($0.id)
            // `.toolGroup` n'existe pas encore ici (`inserting` agit sur des entrées à plat) ; cas gardé pour l'exhaustivité.
            case .item, .toolGroup: true
            }
        }
        guard !cards.isEmpty else { return base }
        let ids = Set(base.map(\.id))
        var replacing: [Int: [WorkflowRunCard]] = [:]
        var anchored: [Int: [WorkflowRunCard]] = [:]
        var head: [WorkflowRunCard] = []
        for card in cards {
            if let id = card.replacesRowId, ids.contains(id) {
                replacing[id, default: []].append(card)
            } else if let id = card.anchorRowId, ids.contains(id) {
                anchored[id, default: []].append(card)
            } else {
                head.append(card)
            }
        }
        var result = head.map { Self.entry(for: $0) }
        for entry in base {
            if let cards = replacing[entry.id] {
                result += cards.map { Self.entry(for: $0, startsTurn: entry.startsTurn) }
            } else {
                result.append(entry)
            }
            result += (anchored[entry.id] ?? []).map { Self.entry(for: $0) }
        }
        return result
    }

    // MARK: Groupes d'outils (lot 13I)

    /// Entrées à plat → entrées groupées. Exige des entrées à plat (une seule application) : un résultat déjà groupé
    /// n'est pas une entrée valable (ses groupes ne se regroupent pas, et leurs membres cachés manquent).
    /// Groupe replié : son entrée, puis ses membres toujours visibles. Déplié : son entrée (en-tête « Réduire ») puis
    /// tous ses membres. Les autres entrées passent telles quelles.
    public static func grouping(_ entries: [ChatEntry], expanded: Set<Int>, pendingInteractionIds: Set<String>) -> [ChatEntry] {
        segments(of: entries).flatMap { segment -> [ChatEntry] in
            guard case .run(let members) = segment else { return segment.entries }
            let first = members[0]
            let isExpanded = expanded.contains(first.id)
            let group = ToolGroup(id: first.id, members: members, isExpanded: isExpanded)
            let head = ChatEntry(id: group.entryId, startsTurn: first.startsTurn, content: .toolGroup(group),
                                 fileChangesTarget: nil, messageTime: nil)
            let shown = isExpanded ? members : members.filter { staysVisible($0, pendingInteractionIds: pendingInteractionIds) }
            return [head] + shown.map { $0.withStartsTurn(false) }
        }
    }

    /// Membre toujours visible sous un groupe replié : outil en flux, en cours, en attente d'autorisation ou en erreur,
    /// outil dont la demande est ouverte, carte de sous-agent, ou réflexion encore en flux.
    public static func staysVisible(_ entry: ChatEntry, pendingInteractionIds: Set<String>) -> Bool {
        if case .item(.reasoning(_, let reasoning)) = entry.content { return reasoning.state == .streaming }
        guard case .item(.tool(_, let call, let link)) = entry.content else { return false }
        if link != nil { return true }
        if let interaction = call.approvalInteractionId, pendingInteractionIds.contains(interaction) { return true }
        return call.status == .inputStreaming || call.status == .running || call.status == .pendingApproval || call.status == .error
    }

    /// Groupe (son `id`) qui contient l'entrée `entryId`, d'après les entrées à plat ; `nil` sinon.
    public static func toolGroupId(containing entryId: Int, in entries: [ChatEntry]) -> Int? {
        for case .run(let members) in segments(of: entries) where members.contains(where: { $0.id == entryId }) {
            return members[0].id
        }
        return nil
    }

    private enum Segment {
        case single(ChatEntry)
        /// Au moins deux outils ou réflexions consécutifs.
        case run([ChatEntry])

        var entries: [ChatEntry] {
            switch self {
            case .single(let entry): [entry]
            case .run(let members): members
            }
        }
    }

    /// Suites d'outils et de réflexions : un `startsTurn` ouvre une nouvelle suite, toute autre entrée la termine ;
    /// une suite d'une seule entrée n'est pas un groupe.
    private static func segments(of entries: [ChatEntry]) -> [Segment] {
        var result: [Segment] = []
        var run: [ChatEntry] = []
        func close() {
            if run.count >= 2 { result.append(.run(run)) } else { result += run.map(Segment.single) }
            run = []
        }
        for entry in entries {
            guard case .item(let item) = entry.content, item.isToolOrReasoning else {
                close()
                result.append(.single(entry))
                continue
            }
            if entry.startsTurn { close() }
            run.append(entry)
        }
        close()
        return result
    }

    /// Valeurs neutres, sauf `startsTurn` repris de l'entrée remplacée.
    private static func entry(for card: WorkflowRunCard, startsTurn: Bool = false) -> ChatEntry {
        ChatEntry(id: card.entryId, startsTurn: startsTurn, content: .workflowRun(card), fileChangesTarget: nil, messageTime: nil)
    }

    private static func item(for row: ConversationRow, link: SubagentLink?) -> ChatItem? {
        switch row.content {
        case .turnHeader:
            return nil
        case .userInput(let value):
            return .user(rowId: row.rowId, value)
        case .assistantText(let value):
            return .assistant(rowId: row.rowId, value)
        case .reasoning(let value):
            let empty = value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return empty ? nil : .reasoning(rowId: row.rowId, value)
        case .toolCall(let value):
            return .tool(rowId: row.rowId, value, subagent: link)
        case .subagent(let value):
            return .subagent(rowId: row.rowId, value)
        case .timelineMarker(let value):
            return value.label.map { .marker(rowId: row.rowId, label: $0) }
        case .unsupported:
            // Les hooks n'ont pas de ligne dans l'interface web ; tout le reste reste visible.
            return row.kind == .hookInvocation ? nil : .unsupported(rowId: row.rowId, kind: row.kind.rawValue, json: row.json)
        }
    }

    /// Association carte Agent ↔ ligne `subagent` (`pairSubagentRows` de `conversationAssistantWorkItems.ts`) :
    /// par `parentToolCallId` dans le même tour ; sans lui (historique ancien), seulement s'il reste exactement une
    /// carte et une ligne dans le tour.
    static func subagentPairs(_ rows: [ConversationRow]) -> (byTool: [Int: SubagentLink], claimed: Set<Int>) {
        var byTool: [Int: SubagentLink] = [:]
        var claimed: Set<Int> = []
        var tools: [String: (row: ConversationRow, call: ToolCall)] = [:]          // clé : tour + identifiant d'appel
        var toolsInOrder: [(row: ConversationRow, call: ToolCall)] = []
        var legacy: [(row: ConversationRow, value: Subagent)] = []
        var subagents: [(row: ConversationRow, value: Subagent)] = []
        for row in rows {
            switch row.content {
            case .toolCall(let call) where SubagentLink.toolNames.contains(call.toolName):
                tools["\(row.turnId ?? "")\u{0}\(call.toolCallId)"] = (row, call)
                toolsInOrder.append((row, call))
            case .subagent(let value):
                subagents.append((row, value))
            default:
                break
            }
        }
        for (row, value) in subagents {
            guard let parent = value.parentToolCallId, !parent.isEmpty else { legacy.append((row, value)); continue }
            guard let turn = row.turnId, let tool = tools["\(turn)\u{0}\(parent)"], byTool[tool.row.rowId] == nil else {
                continue
            }
            byTool[tool.row.rowId] = SubagentLink(tool: tool.row, call: tool.call, subagent: value)
            claimed.insert(row.rowId)
        }
        let remaining = Dictionary(grouping: toolsInOrder.filter { byTool[$0.row.rowId] == nil }) { $0.row.turnId ?? "" }
        for (turn, lines) in Dictionary(grouping: legacy, by: { $0.row.turnId ?? "" }) where !turn.isEmpty {
            guard lines.count == 1, let candidates = remaining[turn], candidates.count == 1 else { continue }
            let tool = candidates[0]
            byTool[tool.row.rowId] = SubagentLink(tool: tool.row, call: tool.call, subagent: lines[0].value)
            claimed.insert(lines[0].row.rowId)
        }
        return (byTool, claimed)
    }
}
