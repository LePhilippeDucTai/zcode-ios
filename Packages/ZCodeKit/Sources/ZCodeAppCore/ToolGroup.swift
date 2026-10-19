import Foundation
import ZCodeV4

/// Famille d'un outil, pour le résumé d'un groupe de cartes (lot 13I). L'ordre des cas est celui du libellé.
public enum ToolFamily: CaseIterable, Sendable {
    case command, read, write, search, web, skill, todo, subagent, other

    /// Nom d'outil sans casse ; inconnu ⇒ `.other`.
    public init(toolName: String) {
        self = switch toolName.lowercased() {
        case "bash", "bashoutput", "killshell": .command
        case "read", "notebookread": .read
        case "write", "edit", "multiedit", "notebookedit", "applypatch": .write
        case "grep", "glob", "ls": .search
        case "webfetch", "websearch": .web
        case "skill": .skill
        case "todowrite": .todo
        case "agent", "task": .subagent
        default: .other
        }
    }

    /// Partie du libellé pour `count` appels (« exécuté 2 commandes »).
    fileprivate func part(count: Int) -> String {
        let plural = count > 1
        return switch self {
        case .command: "exécuté \(count) commande\(plural ? "s" : "")"
        case .read: "lu \(count) fichier\(plural ? "s" : "")"
        case .write: "modifié \(count) fichier\(plural ? "s" : "")"
        case .search: "fait \(count) recherche\(plural ? "s" : "")"
        case .web: "consulté \(count) page\(plural ? "s" : "") web"
        case .skill: "utilisé \(count) skill\(plural ? "s" : "")"
        case .todo: "mis à jour les tâches"
        case .subagent: "lancé \(count) sous-agent\(plural ? "s" : "")"
        case .other: "utilisé \(count) autre\(plural ? "s" : "") outil\(plural ? "s" : "")"
        }
    }
}

/// Groupe de cartes d'outils et de réflexions consécutives, replié sous un résumé (lot 13I).
public struct ToolGroup: Equatable, Sendable, Identifiable {
    /// `rowId` du premier élément : identité stable du groupe.
    public let id: Int
    /// Entrées du groupe, dans l'ordre (seulement `.item(.tool)` et `.item(.reasoning)`).
    public let members: [ChatEntry]
    public let isExpanded: Bool

    public init(id: Int, members: [ChatEntry], isExpanded: Bool) {
        self.id = id
        self.members = members
        self.isExpanded = isExpanded
    }

    /// Identifiant de cellule, disjoint de ceux des entrées (`rowId` ≥ 0, pieds de tour et cartes de workflow, dans
    /// [−(2³²−1), −1]).
    public var entryId: Int { -(1 << 33) - id }

    private var toolCalls: [ToolCall] {
        members.compactMap { if case .item(.tool(_, let call, _)) = $0.content { call } else { nil } }
    }

    private var reasonings: [Reasoning] {
        members.compactMap { if case .item(.reasoning(_, let reasoning)) = $0.content { reasoning } else { nil } }
    }

    /// « A réfléchi, exécuté 9 commandes, lu 2 fichiers · 1 échec »
    public var summary: String {
        var counts: [ToolFamily: Int] = [:]
        for call in toolCalls { counts[ToolFamily(toolName: call.toolName), default: 0] += 1 }
        var parts = ToolFamily.allCases.compactMap { family in counts[family].map { family.part(count: $0) } }
        if !reasonings.isEmpty { parts.insert("réfléchi", at: 0) }
        var text = parts.isEmpty ? "" : "A " + parts.joined(separator: ", ")
        let failures = failureCount
        if failures > 0 { text += " · \(failures) échec\(failures > 1 ? "s" : "")" }
        return text
    }

    public var failureCount: Int { toolCalls.filter { $0.status == .error }.count }

    /// Somme des durées connues (`ToolCall.timing`, réflexions `durationMs`) jusqu'à `now` ; `nil` si aucune.
    public func durationMs(now: Date) -> Double? {
        let nowMs = now.timeIntervalSince1970 * 1000
        let durations: [Double] = toolCalls.compactMap { call in
            switch call.timing {
            case .running(let since): max(0, nowMs - since)
            case .finished(let milliseconds): milliseconds
            case nil: nil
            }
        } + reasonings.compactMap { $0.durationMs.map { max(0, $0) } }
        return durations.isEmpty ? nil : durations.reduce(0, +)
    }

    /// Un membre est en cours (la vue rafraîchit la durée chaque seconde).
    public var isRunning: Bool { toolCalls.contains { $0.status == .running } }
}
