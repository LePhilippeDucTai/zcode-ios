import Foundation
import ZCodeWire

/// Opération d'une trame `deltas` (`delta.ts`).
public enum ConversationDelta: Equatable, Sendable {
    case rowAppended(ConversationRow)
    case rowUpserted(ConversationRow)
    case rowRemoved(fromRowId: Int)
    case rowDelta(rowId: Int, path: StreamablePath, append: String)
    /// Patch d'état : remplacement clé par clé ; une valeur `null` est conservée (elle efface la clé typée).
    case stateUpdated([String: JSONValue])
    /// Opération inconnue (ajoutée par une version plus récente, `pluginUi.*`, `workflowRun.*`) ou mal formée :
    /// ignorée, les autres opérations de la trame s'appliquent.
    case unknown(op: String, raw: JSONValue)

    public init(json: JSONValue) {
        let op = json["op"]?.stringValue ?? ""
        switch op {
        case "row.appended":
            if let row = json["row"].flatMap(ConversationRow.init(json:)) { self = .rowAppended(row); return }
        case "row.upserted":
            if let row = json["row"].flatMap(ConversationRow.init(json:)) { self = .rowUpserted(row); return }
        case "row.removed":
            if let from = V4JSON.integer(json["fromRowId"]) { self = .rowRemoved(fromRowId: from); return }
        case "row.delta":
            if let rowId = V4JSON.integer(json["rowId"]),
               let path = json["path"]?.stringValue,
               let append = json["append"]?.stringValue {
                self = .rowDelta(rowId: rowId, path: StreamablePath(rawValue: path), append: append)
                return
            }
        case "state.updated":
            if let patch = json["patch"]?.objectValue { self = .stateUpdated(patch); return }
        default:
            break
        }
        self = .unknown(op: op, raw: json)
    }
}
