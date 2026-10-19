import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Canal `zcode-task` de l'hôte : archivage des conversations dans son index des tâches (sqlite), la mécanique des
/// interfaces officielles. Une session archivée quitte la liste sans être effacée ; le `taskId` y vaut l'identifiant
/// de session. La suppression définitive pose un tombeau persistant : la conversation disparaît de toutes les listes,
/// mais son contenu reste dans la base de l'hôte (qui n'a aucune API d'effacement).
public struct TaskArchiveClient: Sendable {
    public static let channel = "zcode-task"
    public let client: ChannelClient
    public let workspacePath: String

    public init(client: ChannelClient, workspacePath: String) {
        self.client = client
        self.workspacePath = workspacePath
    }

    public func archive(taskId: String) async throws {
        _ = try await call("archiveTask", ["taskId": .string(taskId), "workspacePath": .string(workspacePath)])
    }

    public func unarchive(taskId: String) async throws {
        _ = try await call("unarchiveTask", ["taskId": .string(taskId), "workspacePath": .string(workspacePath)])
    }

    /// Suppression définituelle d'une tâche encore archivée. `false` : désarchivée entre-temps ou déjà supprimée —
    /// rien n'est effacé alors.
    @discardableResult
    public func deleteArchived(taskId: String) async throws -> Bool {
        let value = try await call("deleteArchivedTask", ["taskId": .string(taskId), "workspacePath": .string(workspacePath)])
        return value.boolValue ?? false
    }

    public func listArchived() async throws -> [ArchivedTask] {
        let value = try await call("listArchivedTasks", ["workspacePath": .string(workspacePath)])
        return ArchivedTask.list(json: value)
    }

    /// Sessions supprimées définitivement (la jointure négative persistante de l'index des sessions).
    public func listDeletedIds() async throws -> Set<String> {
        let value = try await call("listDeletedTaskIds", ["workspacePath": .string(workspacePath)])
        return Set((value.arrayValue ?? []).compactMap(\.stringValue))
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(Self.channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}
