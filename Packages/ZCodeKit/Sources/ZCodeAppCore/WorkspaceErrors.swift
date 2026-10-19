import Foundation
import ZCodeRPC
import ZCodeV4

/// Erreurs des canaux `git` et `file` en français : l'hôte renvoie les erreurs Node brutes (`ENOENT`, `EACCES`…) et
/// des messages en anglais. Un message inconnu est affiché tel quel.
enum WorkspaceErrors {
    static func message(_ error: any Error) -> String {
        guard case RPCError.remote(let remote) = error else { return ConnectionFailure(error).message }
        switch remote.code?.stringValue {
        case "ENOENT": return "Fichier ou dossier introuvable sur l'hôte."
        case "EACCES", "EPERM": return "Accès refusé par l'hôte."
        case "ENOTDIR": return "Ce chemin n'est pas un dossier."
        case "EISDIR": return "Ce chemin est un dossier."
        default: break
        }
        if remote.message.hasPrefix("Path is not a file") { return "Ce chemin n'est pas un fichier." }
        if remote.message.hasPrefix("Path is outside repository scope") { return "Ce fichier est hors du dépôt Git." }
        return remote.message
    }

    /// Raison (en anglais) d'un diff Git indisponible.
    static func gitDiffSummary(_ summary: String?) -> String {
        switch summary {
        case "No Git diff is available for this file.": "Aucun diff Git pour ce fichier."
        case "Git diff command timed out.": "Git a mis trop de temps à produire le diff."
        case "Workspace is not inside a Git repository.": "Le projet n'est pas dans un dépôt Git."
        case "Git binary is not available in the current environment.": "Git est absent de l'hôte."
        case nil: "Diff indisponible."
        case let other?: other
        }
    }

    /// Erreur d'une action Git (messages de l'hôte en anglais, sortie brute de git) ; un message inconnu reste tel quel.
    static func gitAction(_ error: any Error) -> String {
        guard case RPCError.remote(let remote) = error else { return ConnectionFailure(error).message }
        let text = remote.message
        if remote.name == "GitCommitMessageGenerationError" || text.contains("There are no changes available to commit")
            || text.contains("Commit message generation is not available") {
            return "Génération du message impossible : réessaie ou écris-le."
        }
        if text.contains("Commit message cannot be empty") { return "Message de validation vide." }
        if text.contains("Author identity unknown") {
            return "Identité Git absente sur l'hôte : configure user.name et user.email."
        }
        if text.contains("nothing to commit") || text.contains("no changes added to commit") { return "Rien à valider." }
        if text.contains("No Git remote is configured") { return "Aucune distante Git configurée." }
        if text.contains("Multiple Git remotes are configured") {
            return "Plusieurs distantes Git : configure branch.<nom>.remote ou remote.pushDefault."
        }
        if text.contains("Cannot push while HEAD is detached") { return "Impossible de pousser : HEAD détachée." }
        if text.contains("could not read Username") || text.contains("could not read Password")
            || text.contains("Permission denied (publickey)") {
            return "Le push demande des identifiants que l'hôte n'a pas : configure SSH ou le trousseau sur l'hôte."
        }
        if text.contains("timed out after") { return "Git a mis trop de temps (hook ou réseau)." }
        if text.contains("workspace is not inside a Git repository") { return "Le projet n'est pas dans un dépôt Git." }
        if text.contains("Git binary is not available") { return "Git est absent de l'hôte." }
        return message(error)
    }

    /// Blocage d'un changement de branche (libellés de l'interface web traduits) ; deux chemins au plus.
    static func branchIssue(_ issue: GitBranchIssue) -> String {
        let shown = issue.paths.prefix(2).joined(separator: ", ")
        let more = issue.paths.count > 2 ? " et \(issue.paths.count - 2) autres" : ""
        let files = issue.paths.isEmpty ? "" : " (\(shown)\(more))"
        switch issue.code {
        case .invalidBranchName: return "Nom de branche invalide : choisis-en un autre."
        case .branchAlreadyExists: return "Cette branche existe déjà : choisis un autre nom."
        case .targetBranchNotFound: return "Cette branche n'existe pas localement."
        case .trackedChangesWouldBeOverwritten: return "Changement bloqué : des fichiers suivis seraient écrasés\(files)."
        case .untrackedChangesWouldBeOverwritten:
            return "Changement bloqué : des fichiers non suivis seraient écrasés\(files)."
        case .conflictsPresent: return "Le dépôt a des conflits non résolus : résous-les avant de changer de branche."
        case .operationInProgress: return "Une autre opération Git est en cours : termine-la avant de changer de branche."
        case .branchInOtherWorktree: return "Cette branche est déjà extraite dans un autre worktree."
        default:
            let raw = issue.detail ?? issue.message
            return raw.isEmpty ? "Changement de branche impossible : réessaie." : raw
        }
    }
}
