import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

/// Canal `git` de l'hôte : état du dépôt d'un projet, diff d'un fichier et actions (indexer, annuler, valider, pousser,
/// branches).
public struct GitClient: Sendable {
    public static let channel = "git"
    public let client: ChannelClient
    public let workspacePath: String

    public init(client: ChannelClient, workspacePath: String) {
        self.client = client
        self.workspacePath = workspacePath
    }

    /// État et changements indexés / non indexés en un seul `git status` (ce qu'appelle l'interface web). Hors dépôt :
    /// `summary.isRepository == false`, sans erreur.
    public func refresh() async throws -> GitRefreshResult {
        let value = try await call("refresh", [
            "workspacePath": .string(workspacePath), "includeIdentity": .bool(false), "includeBranchComparison": .bool(false),
        ])
        do {
            return try GitRefreshResult(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "git.refresh", detail: "\(error)")
        }
    }

    /// Diff d'un fichier (`path` absolu, celui de `GitFileChange.path`) ; un binaire ou un diff trop gros n'est pas une
    /// erreur (`availability`).
    public func diff(path: String, source: GitDiffSource) async throws -> GitDiffResult {
        let value = try await call("getDiff", [
            "workspacePath": .string(workspacePath), "path": .string(path), "sourceId": .string(source.rawValue),
        ])
        do {
            return try GitDiffResult(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "git.getDiff", detail: "\(error)")
        }
    }

    // MARK: - Actions

    public func stage(paths: [String]) async throws {
        _ = try await call("stagePaths", ["workspacePath": .string(workspacePath), "paths": Self.list(paths)])
    }

    public func unstage(paths: [String]) async throws {
        _ = try await call("unstagePaths", ["workspacePath": .string(workspacePath), "paths": Self.list(paths)])
    }

    /// `staged` : l'index et la copie de travail reviennent à HEAD — un ajout indexé est alors **effacé du disque**, un
    /// renommage indexé perd son nouveau chemin ; sinon la copie revient à l'index. Un fichier non suivi n'est jamais
    /// touché (l'hôte répond par une erreur).
    public func discard(paths: [String], staged: Bool) async throws {
        _ = try await call("discardPaths", [
            "workspacePath": .string(workspacePath), "paths": Self.list(paths), "staged": .bool(staged),
        ])
    }

    /// `stagedOnly` : l'index de ces seuls chemins ; sinon leur contenu de travail (`git commit -- chemins`).
    public func commit(message: String, paths: [String], stagedOnly: Bool) async throws -> GitCommitResult {
        try await decode("commit", GitCommitResult.init(json:), [
            "workspacePath": .string(workspacePath), "message": .string(message), "paths": Self.list(paths),
            "stagedOnly": .bool(stagedOnly),
        ])
    }

    /// Premier push d'une branche : `--set-upstream` sur la distante résolue par l'hôte. Peut durer (10 min au plus).
    public func push() async throws -> GitPushResult {
        try await decode("push", GitPushResult.init(json:), ["workspacePath": .string(workspacePath)])
    }

    public func localBranches() async throws -> GitLocalBranchList {
        try await decode("getLocalBranches", GitLocalBranchList.init(json:), ["workspacePath": .string(workspacePath)])
    }

    public func switchBranch(to name: String) async throws -> GitBranchMutationResult {
        try await decode("switchBranch", GitBranchMutationResult.init(json:), [
            "workspacePath": .string(workspacePath), "targetBranchName": .string(name),
        ])
    }

    /// Crée la branche depuis HEAD et bascule dessus (comme le web, sans point de départ).
    public func createBranch(_ name: String) async throws -> GitBranchMutationResult {
        try await decode("createBranchAndSwitch", GitBranchMutationResult.init(json:), [
            "workspacePath": .string(workspacePath), "branchName": .string(name),
        ])
    }

    /// Un appel du modèle courant de l'hôte. `locale` toujours explicite : sans elle, l'hôte peut répondre en chinois.
    public func generateCommitMessage(includeUnstaged: Bool) async throws -> GitGeneratedCommitMessage {
        try await decode("generateCommitMessage", GitGeneratedCommitMessage.init(json:), [
            "workspacePath": .string(workspacePath), "locale": .string("en-US"), "includeUnstaged": .bool(includeUnstaged),
        ])
    }

    private static func list(_ paths: [String]) -> JSONValue { .array(paths.map(JSONValue.string)) }

    private func decode<T>(
        _ method: String, _ make: (JSONValue) throws(V4DecodingError) -> T, _ params: [String: JSONValue]
    ) async throws -> T {
        let value = try await call(method, params)
        do {
            return try make(value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "git.\(method)", detail: "\(error)")
        }
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(Self.channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}

/// Canal `file` de l'hôte, en lecture seule. L'hôte ne borne rien au projet et n'interprète pas `~` : chemins absolus
/// uniquement (celui du projet ou ceux qu'il renvoie).
public struct FileClient: Sendable {
    public static let channel = "file"
    /// Plafond de `readTextFile` côté hôte (256 Kio).
    public static let maxTextBytes = 262_144
    public let client: ChannelClient

    public init(client: ChannelClient) {
        self.client = client
    }

    public func readdir(path: String, includeHidden: Bool) async throws -> [FileEntry] {
        let value = try await call("readdir", ["path": .string(path), "includeHidden": .bool(includeHidden)])
        do {
            return try FileEntry.list(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "file.readdir", detail: "\(error)")
        }
    }

    /// Les 256 premiers Kio ; un fichier plus gros revient `truncated`, un binaire `isBinary` (pas d'erreur).
    public func readTextFile(path: String) async throws -> FileTextSlice {
        let value = try await call("readTextFile", ["path": .string(path), "length": .number(Double(Self.maxTextBytes))])
        do {
            return try FileTextSlice(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "file.readTextFile", detail: "\(error)")
        }
    }

    /// Recherche floue de l'hôte dans `root` (dossiers et fichiers cachés compris).
    public func search(root: String, query: String, limit: Int = 200) async throws -> [WorkspaceFileMatch] {
        let value = try await call("searchWorkspaceFiles", [
            "rootPath": .string(root), "query": .string(query), "limit": .number(Double(limit)),
        ])
        do {
            return try WorkspaceFileMatch.list(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: "file.searchWorkspaceFiles", detail: "\(error)")
        }
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await client.call(Self.channel, method, .array([RPCValue(.object(params))])).jsonValue ?? .null
    }
}
