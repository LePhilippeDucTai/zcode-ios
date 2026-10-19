import Foundation
import ZCodeWire

public struct GitChangeKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let modified = GitChangeKind(rawValue: "modified")
    public static let added = GitChangeKind(rawValue: "added")
    public static let deleted = GitChangeKind(rawValue: "deleted")
    public static let renamed = GitChangeKind(rawValue: "renamed")
}

/// Section d'un changement dans le panneau Git de ZCode.
public struct GitChangeSection: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let staged = GitChangeSection(rawValue: "staged")
    public static let unstaged = GitChangeSection(rawValue: "unstaged")
    public static let untracked = GitChangeSection(rawValue: "untracked")
    public static let conflicted = GitChangeSection(rawValue: "conflicted")
}

/// Fichier modifié du dépôt (`GitFileChange`). Un renommage ne porte que le nouveau chemin : l'ancien est perdu par
/// ZCode 3.15.1.
public struct GitFileChange: Hashable, Sendable, Identifiable {
    /// Chemin absolu sur l'hôte.
    public let path: String
    public let workspaceRelativePath: String
    public let kind: GitChangeKind
    public let section: GitChangeSection
    public let added: Int
    public let removed: Int
    public let isStaged: Bool
    public let isUntracked: Bool
    public let isConflicted: Bool

    /// Un même fichier peut être à la fois indexé et modifié depuis : la section fait partie de l'identité.
    public var id: String { "\(section.rawValue):\(path)" }
    /// Dossier non suivi résumé en une entrée (mode dégradé de l'hôte au-delà de 512 Kio de statut) : pas de diff.
    public var isDirectory: Bool { path.hasSuffix("/") }

    init?(json: JSONValue) {
        guard let path = json["path"]?.stringValue, !path.isEmpty else { return nil }
        self.path = path
        workspaceRelativePath = json["workspaceRelativePath"]?.stringValue ?? path
        kind = GitChangeKind(rawValue: json["kind"]?.stringValue ?? "modified")
        section = GitChangeSection(rawValue: json["section"]?.stringValue ?? "unstaged")
        added = V4JSON.integer(json["added"]) ?? 0
        removed = V4JSON.integer(json["removed"]) ?? 0
        isStaged = json["isStaged"]?.boolValue ?? false
        isUntracked = json["isUntracked"]?.boolValue ?? false
        isConflicted = json["isConflicted"]?.boolValue ?? false
    }
}

/// État du dépôt du projet (`GitRepositorySummary`). Hors dépôt : `isRepository == false`, sans erreur.
public struct GitRepositorySummary: Equatable, Sendable {
    public let isRepository: Bool
    public let isGitAvailable: Bool
    public let branchName: String?
    public let trackingBranchName: String?
    /// `branch` ou `detached`.
    public let headRefType: String
    public let ahead: Int
    public let behind: Int
    public let isDirty: Bool

    init(json: JSONValue?) {
        isRepository = json?["isRepository"]?.boolValue ?? false
        isGitAvailable = json?["isGitAvailable"]?.boolValue ?? true
        branchName = json?["branchName"]?.stringValue
        trackingBranchName = json?["trackingBranchName"]?.stringValue
        headRefType = json?["headRefType"]?.stringValue ?? "branch"
        ahead = V4JSON.integer(json?["ahead"]) ?? 0
        behind = V4JSON.integer(json?["behind"]) ?? 0
        isDirty = json?["isDirty"]?.boolValue ?? false
    }
}

/// Réponse de `git.refresh` : un seul `git status` pour l'état et les deux listes (comme l'interface web).
public struct GitRefreshResult: Equatable, Sendable {
    public let summary: GitRepositorySummary
    public let stagedChanges: [GitFileChange]
    /// Non indexés, non suivis et en conflit (sections `unstaged`, `untracked`, `conflicted`).
    public let unstagedChanges: [GitFileChange]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("git.refresh") }
        summary = GitRepositorySummary(json: json["summary"])
        stagedChanges = (json["stagedChanges"]?.arrayValue ?? []).compactMap(GitFileChange.init(json:))
        unstagedChanges = (json["unstagedChanges"]?.arrayValue ?? []).compactMap(GitFileChange.init(json:))
    }
}

public struct GitDiffAvailability: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let patch = GitDiffAvailability(rawValue: "patch")
    public static let binary = GitDiffAvailability(rawValue: "binary")
    /// Sortie de `git diff` au-delà de 1 Mio.
    public static let truncated = GitDiffAvailability(rawValue: "truncated")
    public static let unavailable = GitDiffAvailability(rawValue: "unavailable")
}

/// Côté du diff demandé à `git.getDiff`.
public enum GitDiffSource: String, Sendable {
    case unstaged, staged
}

/// Réponse de `git.getDiff`. Un binaire ou un diff trop gros n'est pas une erreur : `availability` + `summary`.
public struct GitDiffResult: Equatable, Sendable {
    public let path: String
    public let availability: GitDiffAvailability
    /// Texte brut de `git diff` (patch synthétique sans `diff --git` pour un fichier non suivi) si `patch`.
    public let patch: String?
    /// Raison, en anglais, quand le diff n'est pas affichable.
    public let summary: String?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("git.getDiff") }
        path = json["path"]?.stringValue ?? ""
        availability = GitDiffAvailability(rawValue: json["availability"]?.stringValue ?? "unavailable")
        patch = json["patch"]?.stringValue
        summary = json["summary"]?.stringValue
    }
}

// MARK: - Actions (canal `git`, mutations)

/// Code d'un blocage de changement de branche (`GitBranchMutationIssueCode`).
public struct GitBranchIssueCode: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let invalidBranchName = GitBranchIssueCode(rawValue: "invalid-branch-name")
    public static let branchAlreadyExists = GitBranchIssueCode(rawValue: "branch-already-exists")
    public static let targetBranchNotFound = GitBranchIssueCode(rawValue: "target-branch-not-found")
    public static let trackedChangesWouldBeOverwritten = GitBranchIssueCode(rawValue: "tracked-changes-would-be-overwritten")
    public static let untrackedChangesWouldBeOverwritten = GitBranchIssueCode(rawValue: "untracked-changes-would-be-overwritten")
    public static let conflictsPresent = GitBranchIssueCode(rawValue: "conflicts-present")
    public static let operationInProgress = GitBranchIssueCode(rawValue: "operation-in-progress")
    public static let branchInOtherWorktree = GitBranchIssueCode(rawValue: "branch-in-other-worktree")
    public static let unknown = GitBranchIssueCode(rawValue: "unknown")
}

public struct GitBranchIssue: Equatable, Sendable {
    public let code: GitBranchIssueCode
    /// Message de l'hôte, en anglais.
    public let message: String
    /// Fichiers en cause, **relatifs au dépôt** (pas au projet).
    public let paths: [String]
    /// Sortie brute de git.
    public let detail: String?

    init(json: JSONValue) {
        code = GitBranchIssueCode(rawValue: json["code"]?.stringValue ?? "unknown")
        message = json["message"]?.stringValue ?? ""
        paths = (json["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
        detail = json["detail"]?.stringValue
    }
}

/// Réponse de `git.switchBranch` / `git.createBranchAndSwitch` : un blocage connu n'est pas une erreur (`ok: false`
/// et une `issue`).
public struct GitBranchMutationResult: Equatable, Sendable {
    public let ok: Bool
    public let branchName: String?
    public let didChange: Bool
    public let created: Bool
    public let summary: GitRepositorySummary?
    public let issues: [GitBranchIssue]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("git.branchMutation") }
        ok = json["ok"]?.boolValue ?? false
        branchName = json["branchName"]?.stringValue
        didChange = json["didChange"]?.boolValue ?? false
        created = json["created"]?.boolValue ?? false
        summary = json["summary"]?.objectValue == nil ? nil : GitRepositorySummary(json: json["summary"])
        issues = (json["issues"]?.arrayValue ?? []).map(GitBranchIssue.init(json:))
    }
}

public struct GitCommitResult: Equatable, Sendable {
    public let commitHash: String
    public let summary: GitRepositorySummary?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let hash = json["commitHash"]?.stringValue else { throw .missingField("commitHash") }
        commitHash = hash
        summary = json["summary"]?.objectValue == nil ? nil : GitRepositorySummary(json: json["summary"])
    }
}

public struct GitPushResult: Equatable, Sendable {
    public let branchName: String?
    public let trackingBranchName: String?
    public let remoteName: String?
    /// Premier push de la branche : elle a été publiée et son upstream réglé.
    public let setUpstream: Bool
    public let summary: GitRepositorySummary?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("git.push") }
        branchName = json["branchName"]?.stringValue
        trackingBranchName = json["trackingBranchName"]?.stringValue
        remoteName = json["remoteName"]?.stringValue
        setUpstream = json["setUpstream"]?.boolValue ?? false
        summary = json["summary"]?.objectValue == nil ? nil : GitRepositorySummary(json: json["summary"])
    }
}

public struct GitLocalBranch: Equatable, Sendable, Identifiable {
    public let name: String
    public let isCurrent: Bool
    public let upstreamName: String?
    public let commitTimestampMs: Double?

    public var id: String { name }
}

/// Réponse de `git.getLocalBranches` (branches locales, la plus récemment validée d'abord).
public struct GitLocalBranchList: Equatable, Sendable {
    public let headRefType: String
    public let currentBranchName: String?
    public let branches: [GitLocalBranch]

    public init(json: JSONValue) throws(V4DecodingError) {
        guard json.objectValue != nil else { throw .invalid("git.getLocalBranches") }
        headRefType = json["headRefType"]?.stringValue ?? "branch"
        currentBranchName = json["currentBranchName"]?.stringValue
        branches = (json["branches"]?.arrayValue ?? []).compactMap { branch in
            guard let name = branch["name"]?.stringValue else { return nil }
            return GitLocalBranch(name: name, isCurrent: branch["isCurrent"]?.boolValue ?? false,
                                  upstreamName: branch["upstreamName"]?.stringValue,
                                  commitTimestampMs: branch["commitTimestampMs"]?.numberValue)
        }
    }
}

/// Réponse de `git.generateCommitMessage` (un appel du modèle courant de l'hôte).
public struct GitGeneratedCommitMessage: Equatable, Sendable {
    public let message: String
    public let model: String?

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let message = json["message"]?.stringValue else { throw .missingField("message") }
        self.message = message
        model = json["model"]?.stringValue
    }
}
