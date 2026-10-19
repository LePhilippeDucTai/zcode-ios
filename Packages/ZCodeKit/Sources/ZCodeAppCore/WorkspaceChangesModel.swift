import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Diff d'un fichier prêt à afficher, ou la raison de son absence.
public enum DiffLoad: Equatable, Sendable {
    case loaded([FileDiff])
    case unavailable(String)
}

/// Action Git en cours.
public enum GitAction: Equatable, Sendable {
    case stage, unstage, discard, commit, push, branch, generateMessage
}

/// Issue d'un changement ou d'une création de branche.
public enum BranchOutcome: Equatable, Sendable {
    case switched(String)
    case unchanged
    /// Des modifications seraient écrasées : proposer de les valider puis de rebasculer (`commitAndSwitch`).
    case needsCommit(branch: String, paths: [String])
    case failed(String)
}

/// Modifications du dépôt Git d'un projet (canal `git`) et actions : indexer, annuler, valider, pousser, branches.
@MainActor
@Observable
public final class WorkspaceChangesModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// Le projet n'est pas dans un dépôt Git (ou Git est absent de l'hôte) : ce n'est pas une erreur.
        case notRepository
        case failed(String)
    }

    public let workspace: String
    public private(set) var phase: Phase = .idle
    public private(set) var summary: GitRepositorySummary?
    public private(set) var staged: [GitFileChange] = []
    public private(set) var unstaged: [GitFileChange] = []
    public private(set) var untracked: [GitFileChange] = []
    public private(set) var conflicted: [GitFileChange] = []
    /// Action en cours (une seule à la fois) : les boutons sont désactivés.
    public private(set) var action: GitAction?
    public private(set) var actionError: String?
    /// Succès à afficher brièvement (« Validé (abc1234) », « Poussé vers origin/main »).
    public private(set) var notice: String?
    public private(set) var branches: [GitLocalBranch] = []
    private let connection: HostConnection
    @ObservationIgnored private var generation = 0

    public init(connection: HostConnection, workspace: String) {
        self.connection = connection
        self.workspace = workspace
    }

    public var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty }

    /// Relit l'état (à l'ouverture, en tirant la liste) ; l'ancienne liste reste affichée pendant la lecture.
    public func refresh() async {
        generation += 1
        let generation = self.generation
        if summary == nil { phase = .loading }
        guard let channel = await connection.ensureConnected() else {
            guard generation == self.generation else { return }
            phase = .failed(connection.failure?.message ?? "Hôte injoignable.")
            return
        }
        do {
            let result = try await GitClient(client: channel, workspacePath: workspace).refresh()
            guard generation == self.generation else { return }
            summary = result.summary
            staged = result.stagedChanges
            untracked = result.unstagedChanges.filter { $0.section == .untracked }
            conflicted = result.unstagedChanges.filter { $0.section == .conflicted }
            // Section inconnue de l'app : rangée avec les modifications non indexées plutôt que perdue.
            unstaged = result.unstagedChanges.filter { $0.section != .untracked && $0.section != .conflicted }
            phase = result.summary.isRepository ? .ready : .notRepository
        } catch {
            guard generation == self.generation else { return }
            phase = .failed("Modifications indisponibles : \(WorkspaceErrors.message(error))")
        }
    }

    /// Diff d'un fichier (indexé ou non selon sa section), lu à chaque ouverture.
    public func diff(for change: GitFileChange) async -> DiffLoad {
        guard !change.isDirectory else { return .unavailable("Dossier non suivi : ouvre-le dans « Fichiers ».") }
        guard let channel = await connection.ensureConnected() else {
            return .unavailable(connection.failure?.message ?? "Hôte injoignable.")
        }
        do {
            let result = try await GitClient(client: channel, workspacePath: workspace)
                .diff(path: change.path, source: change.isStaged ? .staged : .unstaged)
            return Self.load(result)
        } catch {
            return .unavailable("Diff indisponible : \(WorkspaceErrors.message(error))")
        }
    }

    static func load(_ result: GitDiffResult) -> DiffLoad {
        switch result.availability {
        case .patch:
            let files = UnifiedDiff.parse(result.patch ?? "")
            guard files.contains(where: { !$0.hunks.isEmpty }) else {
                return .unavailable("Aucune ligne modifiée (changement de mode ou fichier vide).")
            }
            return .loaded(files)
        case .binary:
            return .unavailable("Fichier binaire : pas d'aperçu du diff.")
        case .truncated:
            return .unavailable("Diff trop volumineux pour l'aperçu (plus de 1 Mio) : ouvre l'interface web.")
        default:
            return .unavailable(WorkspaceErrors.gitDiffSummary(result.summary))
        }
    }

    // MARK: - Actions

    public func dismissActionMessages() {
        actionError = nil
        notice = nil
    }

    public func stage(_ changes: [GitFileChange]) async {
        await mutate(.stage) { try await $0.stage(paths: changes.map(\.path)) }
    }

    public func unstage(_ changes: [GitFileChange]) async {
        await mutate(.unstage) { try await $0.unstage(paths: changes.map(\.path)) }
    }

    /// Pas d'annulation pour un non suivi (ZCode n'a pas de `git clean`), un conflit, un dossier, ni pour un ajout ou un
    /// renommage indexés : `git restore --source=HEAD` effacerait le fichier du disque (contenu jamais validé, ou ancien
    /// chemin perdu par l'hôte).
    public func canDiscard(_ change: GitFileChange) -> Bool {
        guard !change.isUntracked, !change.isConflicted, !change.isDirectory else { return false }
        return !(change.isStaged && (change.kind == .added || change.kind == .renamed))
    }

    /// Indexé : l'index et la copie reviennent au dernier commit ; sinon la copie revient à l'index. Irréversible.
    public func discard(_ change: GitFileChange) async {
        guard canDiscard(change) else { return }
        await mutate(.discard) { try await $0.discard(paths: [change.path], staged: change.isStaged) }
    }

    /// Valide (règles de l'interface web, sur tous les fichiers du dépôt) : message vide → généré par le modèle courant de
    /// l'hôte ; `includeUnstaged` → non indexés et non suivis indexés d'abord. `true` si le commit a eu lieu (même si le
    /// push demandé ensuite échoue).
    public func commit(message: String, includeUnstaged: Bool, push: Bool) async -> Bool {
        guard action == nil else { return false }
        let extra = includeUnstaged ? (unstaged + untracked).map(\.path) : []
        let paths = staged.map(\.path) + extra
        guard !paths.isEmpty else {
            actionError = "Rien à valider : indexe des fichiers ou inclus les modifications non indexées."
            return false
        }
        dismissActionMessages()
        action = .commit
        defer { action = nil }
        guard let git = await client() else { return false }
        do {
            var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                action = .generateMessage
                text = try await git.generateCommitMessage(includeUnstaged: includeUnstaged).message
            }
            action = .commit
            if !extra.isEmpty { try await git.stage(paths: extra) }
            // Tout vient d'être indexé : valider l'index entier. `git commit -- chemins` ne garderait d'un renommage indexé
            // que le nouveau chemin (l'ancien resterait indexé, hors du commit).
            let result = try await git.commit(message: text, paths: includeUnstaged ? [] : paths, stagedOnly: !includeUnstaged)
            notice = "Validé (\(result.commitHash.prefix(7)))"
        } catch {
            actionError = WorkspaceErrors.gitAction(error)
            await refresh()
            return false
        }
        if push {
            action = .push
            do {
                notice = Self.pushed(try await git.push())
            } catch {
                actionError = "Validé, mais le push a échoué : \(WorkspaceErrors.gitAction(error))"
            }
        }
        await refresh()
        return true
    }

    /// Sur une branche, sans upstream (premier push : publication) ou en avance (règle `canPushGitBranch` du web).
    public var canPush: Bool {
        guard let summary, summary.isRepository, summary.headRefType == "branch", summary.branchName != nil else { return false }
        return summary.trackingBranchName == nil || summary.ahead > 0
    }

    public func push() async -> Bool {
        guard action == nil else { return false }
        dismissActionMessages()
        action = .push
        defer { action = nil }
        guard let git = await client() else { return false }
        do {
            notice = Self.pushed(try await git.push())
        } catch {
            actionError = WorkspaceErrors.gitAction(error)
            return false
        }
        await refresh()
        return true
    }

    public func loadBranches() async {
        guard let git = await client() else { return }
        do {
            branches = try await git.localBranches().branches
        } catch {
            actionError = WorkspaceErrors.gitAction(error)
        }
    }

    /// Un échec est aussi rangé dans `actionError` (affiché par l'écran).
    public func switchBranch(to name: String) async -> BranchOutcome {
        reported(await mutateBranch(name) { try await $0.switchBranch(to: name) })
    }

    /// Crée la branche depuis HEAD et bascule dessus.
    public func createBranch(_ name: String) async -> BranchOutcome {
        let name = name.trimmingCharacters(in: .whitespaces)
        return reported(await mutateBranch(name) { try await $0.createBranch(name) })
    }

    private func reported(_ outcome: BranchOutcome) -> BranchOutcome {
        if case .failed(let reason) = outcome { actionError = reason }
        return outcome
    }

    /// Valide toutes les modifications (non suivis compris) puis rebascule — message vide : celui, fixe, du web.
    public func commitAndSwitch(to name: String, message: String) async -> BranchOutcome {
        guard action == nil else { return .failed("Une action Git est déjà en cours.") }
        dismissActionMessages()
        action = .commit
        guard let git = await client() else { action = nil; return .failed(actionError ?? "Hôte injoignable.") }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pending = (unstaged + untracked).map(\.path)
            if !pending.isEmpty { try await git.stage(paths: pending) }
            _ = try await git.commit(message: text.isEmpty ? "chore: checkpoint before switching to \(name)" : text,
                                     paths: [], stagedOnly: false)
        } catch {
            action = nil
            actionError = WorkspaceErrors.gitAction(error)
            await refresh()
            return .failed(actionError ?? "")
        }
        action = nil
        return await switchBranch(to: name)
    }

    // MARK: - Mécanique des actions

    private func client() async -> GitClient? {
        guard let channel = await connection.ensureConnected() else {
            actionError = connection.failure?.message ?? "Hôte injoignable."
            return nil
        }
        return GitClient(client: channel, workspacePath: workspace)
    }

    /// Action sans résultat : une à la fois, puis relecture de l'état.
    private func mutate(_ kind: GitAction, _ body: (GitClient) async throws -> Void) async {
        guard action == nil else { return }
        dismissActionMessages()
        action = kind
        defer { action = nil }
        guard let git = await client() else { return }
        do {
            try await body(git)
        } catch {
            actionError = WorkspaceErrors.gitAction(error)
        }
        await refresh()
    }

    private func mutateBranch(_ name: String, _ body: (GitClient) async throws -> GitBranchMutationResult) async -> BranchOutcome {
        guard action == nil else { return .failed("Une action Git est déjà en cours.") }
        dismissActionMessages()
        action = .branch
        defer { action = nil }
        guard let git = await client() else { return .failed(actionError ?? "Hôte injoignable.") }
        let result: GitBranchMutationResult
        do {
            result = try await body(git)
        } catch {
            return .failed(WorkspaceErrors.gitAction(error))
        }
        if result.ok {
            guard result.didChange || result.created else { return .unchanged }
            await loadBranches()
            await refresh()
            return .switched(result.branchName ?? name)
        }
        guard let issue = result.issues.first else { return .failed("Changement de branche impossible : réessaie.") }
        if issue.code == .trackedChangesWouldBeOverwritten || issue.code == .untrackedChangesWouldBeOverwritten {
            return .needsCommit(branch: name, paths: issue.paths)
        }
        return .failed(WorkspaceErrors.branchIssue(issue))
    }

    private static func pushed(_ result: GitPushResult) -> String {
        "Poussé vers \(result.trackingBranchName ?? result.branchName ?? "la distante")"
    }
}
