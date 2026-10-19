import Foundation
import ZCodeWire

/// État d'une conversation tel que projeté par ZCode (`snapshot.ts`), mis à jour par les deltas (`apply.ts`).
public struct ConversationSnapshot: Equatable, Sendable {
    /// Toutes les clés du snapshot sauf `rows` (révision, contrôle, config, interactions, Goal…).
    public private(set) var state: [String: JSONValue]
    /// Fenêtre de lignes chargées, triée par `rowId`.
    public private(set) var rows: [ConversationRow]
    /// Nombre de lignes de la branche active côté serveur (≥ lignes chargées).
    public private(set) var totalCount: Int
    /// Première ligne de la branche active ; sert d'ancre pour charger l'historique.
    public private(set) var firstRowId: Int?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard var object = json.objectValue else { throw .invalid("snapshot") }
        guard object["sessionId"]?.stringValue != nil else { throw .missingField("sessionId") }
        guard object["logEpoch"]?.stringValue != nil else { throw .missingField("logEpoch") }
        guard let rowsObject = object.removeValue(forKey: "rows"), let window = rowsObject["window"]?.arrayValue else {
            throw .missingField("rows")
        }
        let rows = window.compactMap(ConversationRow.init(json:)).sorted { $0.rowId < $1.rowId }
        self.state = object
        self.rows = rows
        self.totalCount = V4JSON.integer(rowsObject["totalCount"]) ?? rows.count
        self.firstRowId = V4JSON.integer(rowsObject["firstRowId"])
    }

    // MARK: - Lecture

    public var sessionId: String { state["sessionId"]?.stringValue ?? "" }
    public var logEpoch: String { state["logEpoch"]?.stringValue ?? "" }
    /// Révision structurelle, à renvoyer dans les commandes CAS (`baseRevision`).
    public var revision: Int { V4JSON.integer(state["revision"]) ?? 0 }
    public var control: SessionControl? { decoded("control") }
    public var config: SessionConfig? { decoded("config") }
    public var meta: SessionMeta? { decoded("meta") }
    public var inputRouting: InputRouting? { decoded("inputRouting") }
    public var goal: GoalState? { decoded("goal") }

    public var usage: ContextUsage? {
        guard let window = state["usage"]?["contextWindow"], window != .null else { return nil }
        return try? V4JSON.decode(ContextUsage.self, from: window)
    }

    public var availability: [String: ActionAvailability] {
        (state["availability"]?.objectValue ?? [:]).compactMapValues { try? V4JSON.decode(ActionAvailability.self, from: $0) }
    }

    public var pendingInteractions: [PendingInteraction] {
        (state["pendingInteractions"]?.arrayValue ?? []).compactMap(PendingInteraction.init(json:))
    }

    public var queue: QueueState? {
        guard let queue = state["queue"], queue != .null else { return nil }
        return QueueState(
            items: (queue["items"]?.arrayValue ?? []).compactMap { try? V4JSON.decode(QueueItem.self, from: $0) },
            autoDrain: queue["autoDrain"]?.boolValue,
            pauseReason: queue["pauseReason"]?.stringValue
        )
    }

    public func row(id: Int) -> ConversationRow? {
        rows.first { $0.rowId == id }
    }

    /// Copie hors ligne (lot 13E-1) : le JSON exact qu'accepte `init(json:)`, réduit aux `maxRows` dernières lignes
    /// (pages d'historique chargées laissées de côté). `totalCount` et `firstRowId` restent ceux de l'hôte.
    public func offlineJSON(keepingLast maxRows: Int) -> JSONValue {
        var rowsObject: [String: JSONValue] = [
            "window": .array(rows.suffix(maxRows).map(\.json)),
            "totalCount": .number(Double(totalCount)),
        ]
        if let firstRowId { rowsObject["firstRowId"] = .number(Double(firstRowId)) }
        var object = state
        object["rows"] = .object(rowsObject)
        return .object(object)
    }

    // MARK: - Application des deltas

    public mutating func apply(_ deltas: [ConversationDelta]) {
        for delta in deltas {
            apply(delta)
        }
    }

    public mutating func apply(_ delta: ConversationDelta) {
        switch delta {
        case .rowAppended(let row):
            if let index = rows.firstIndex(where: { $0.rowId == row.rowId }) {
                // Écart volontaire avec apply.ts : un rejeu ne doit pas créer deux lignes de même identifiant.
                rows[index] = row
            } else {
                rows.append(row)
                totalCount += 1
                if firstRowId == nil { firstRowId = row.rowId }
            }
        case .rowUpserted(let row):
            // Ligne non chargée : sans effet (elle reviendra par `rowsRange`).
            if let index = rows.firstIndex(where: { $0.rowId == row.rowId }) {
                rows[index] = row
            }
        case .rowRemoved(let fromRowId):
            let kept = rows.filter { $0.rowId < fromRowId }
            let removed = rows.count - kept.count
            rows = kept
            if let first = firstRowId, fromRowId <= first {
                totalCount = 0
                firstRowId = nil
            } else {
                totalCount = max(0, totalCount - removed)
            }
        case .rowDelta(let rowId, let path, let append):
            if let index = rows.firstIndex(where: { $0.rowId == rowId }) {
                rows[index] = rows[index].appending(append, at: path)
            }
        case .stateUpdated(let patch):
            for (key, value) in patch where key != "rows" {
                state[key] = value
            }
        case .unknown:
            break
        }
    }

    /// Ajoute une page d'historique (`rowsRange`) sans doublon, en gardant l'ordre des `rowId`.
    public mutating func insertOlderRows(_ older: [ConversationRow]) {
        let known = Set(rows.map(\.rowId))
        let fresh = older.filter { !known.contains($0.rowId) }
        guard !fresh.isEmpty else { return }
        rows = (fresh + rows).sorted { $0.rowId < $1.rowId }
    }

    private func decoded<T: Decodable>(_ key: String) -> T? {
        guard let value = state[key], value != .null else { return nil }
        return try? V4JSON.decode(T.self, from: value)
    }
}
