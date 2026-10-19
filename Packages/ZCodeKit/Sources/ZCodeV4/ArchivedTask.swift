import Foundation
import ZCodeWire

/// Tâche archivée de l'index des tâches de l'hôte (`listArchivedTasks`). Le `taskId` y vaut l'identifiant de la
/// session ; `updatedAt` est sa dernière activité, pas une date d'archivage (l'hôte n'en écrit pas).
public struct ArchivedTask: Equatable, Sendable {
    public let taskId: String
    public let title: String
    public let updatedAt: Date?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let taskId = json["taskId"]?.stringValue else { throw .missingField("taskId") }
        self.taskId = taskId
        title = json["title"]?.stringValue ?? ""
        guard let milliseconds = json["updatedAt"]?.numberValue, milliseconds.isFinite, milliseconds > 0 else {
            updatedAt = nil
            return
        }
        updatedAt = Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Liste tolérante : une entrée mal formée est ignorée.
    public static func list(json: JSONValue) -> [ArchivedTask] {
        (json.arrayValue ?? []).compactMap { try? ArchivedTask(json: $0) }
    }
}
