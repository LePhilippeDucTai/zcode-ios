import Foundation
import ZCodeV4

/// Libellés des workflows enregistrés : refus de l'hôte traduits par `reasonCode`, section vide.
public enum WorkflowLabels {
    /// Les refus réels de l'hôte ont `status: "failed"` ; le code de raison porte la cause.
    public static func startRefusal(reasonCode: String?, status: String) -> String {
        switch reasonCode {
        case "fault.command.savedWorkflowStartRejected.invalid_name": "Nom de workflow invalide."
        case "fault.command.savedWorkflowStartRejected.not_found": "Workflow introuvable ou illisible sur l'hôte."
        case "fault.command.savedWorkflowStartRejected.invalid_args": "Arguments refusés par l'hôte."
        case "fault.command.savedWorkflowStartRejected.compile_failed": "Le script du workflow ne compile pas."
        case "fault.command.savedWorkflowStartRejected.session_busy": "La session est occupée."
        case "fault.command.savedWorkflowStartRejected.start_failed": "Le workflow n'a pas pu démarrer."
        case "fault.command.capabilityUnsupported": "Cet hôte ne sait pas lancer de workflow enregistré."
        default: "Lancement refusé par l'hôte (\(reasonCode ?? status))."
        }
    }

    /// Exception (réseau, hôte injoignable, création refusée) : le détail technique va dans `detail`.
    public static let launchFailed = "Le lancement a échoué."
    public static let launchInProgress = "Un lancement est déjà en cours."

    /// Section de la liste en échec : message de connexion pour une panne de connexion (même règle que
    /// `ExtensionsHost.isOffline`), sinon un libellé fixe (les erreurs de l'hôte n'ont pas de texte français).
    public static func listFailure(_ error: any Error) -> String {
        ExtensionsHost.isOffline(error) ? ConnectionFailure(error).message : "Lecture impossible."
    }

    public static func cancelRefusal(reasonCode: String?) -> String {
        switch reasonCode {
        case "fault.command.backgroundWorkCancelRejected.not_found": "Ce run n'existe plus."
        case "fault.command.backgroundWorkCancelRejected.not_running": "Ce run est déjà terminé."
        case "fault.command.backgroundWorkCancelRejected.cancel_not_supported": "Ce run ne peut pas être arrêté."
        default: "Arrêt refusé par l'hôte."
        }
    }

    /// Statut d'un agent sur sa pastille ; valeur inconnue affichée brute.
    public static func actorStatus(_ status: WorkflowActorStatus) -> String {
        switch status {
        case .waiting: "En attente"
        case .running: "Au travail"
        case .completed: "Terminé"
        default: status.rawValue
        }
    }

    /// Statut d'un run sur sa carte ; valeur inconnue affichée brute (décodage tolérant).
    public static func runStatus(_ status: WorkflowRunStatus) -> String {
        switch status {
        case .running: "En cours"
        case .completed: "Terminé"
        case .errored: "Erreur"
        case .stopped: "Arrêté"
        case .pending: "En attente"
        default: status.rawValue
        }
    }

    /// Mention de la liste des sessions : dernier run de `workflowActivity.runs` (l'appelant passe
    /// `summary.workflowActivity?.runs`) ; `nil` sans run. Statut inconnu : « Workflow » seul.
    public static func activity(_ activity: [WorkflowActivity]?) -> String? {
        guard let run = activity?.last else { return nil }
        switch run.status {
        case .running, .pending:
            guard let phase = run.currentPhase, !phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Workflow en cours"
            }
            return "Workflow : \(phase)"
        case .completed: return "Workflow terminé"
        case .stopped: return "Workflow arrêté"
        case .errored: return "Workflow en erreur"
        default: return "Workflow"
        }
    }

    public static func emptySection(dir: String?) -> String {
        guard let dir, !dir.isEmpty else { return "Aucun workflow." }
        return "Aucun workflow. Dossier sur l'hôte : \(dir)"
    }
}
