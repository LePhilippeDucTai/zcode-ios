import Foundation
import ZCodeRPC
import ZCodeV4

extension ToolCallStatus {
    public var label: String {
        switch self {
        case .inputStreaming: "Préparation"
        case .pendingApproval: "En attente d'approbation"
        case .running: "En cours"
        case .success: "Terminé"
        case .error: "Échec"
        case .cancelled: "Annulé"
        default: rawValue
        }
    }
}

extension ToolCall {
    /// Argument le plus parlant (fichier, commande, motif, adresse…), sinon début des arguments bruts.
    public var summary: String? {
        for key in ["file_path", "path", "command", "pattern", "url", "query", "description", "prompt"] {
            if let value = input?[key]?.stringValue, !value.isEmpty { return value }
        }
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw == "{}" ? nil : String(raw.prefix(80))
    }
}

extension TurnHeader {
    /// Pied du tour ; `nil` pour un état inconnu.
    public var summaryLabel: String? {
        switch state {
        case .running: "En cours…"
        case .completedSuccess: activeMs.map { "Terminé en \(Self.duration($0))" } ?? "Terminé"
        case .completedInterrupted: "Interrompu"
        case .failed: "Échec du tour"
        default: nil
        }
    }

    public var fileChangesLabel: String? {
        guard let changes = fileChanges, changes.files > 0 else { return nil }
        let files = changes.files == 1 ? "1 fichier modifié" : "\(changes.files) fichiers modifiés"
        return "\(files) (+\(changes.additions) −\(changes.deletions))"
    }

    static func duration(_ milliseconds: Double) -> String {
        let seconds = Int((milliseconds / 1000).rounded(.up))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

extension Reasoning {
    public var label: String {
        if state == .streaming { return "Réflexion…" }
        return durationMs.map { "Réflexion (\(TurnHeader.duration($0)))" } ?? "Réflexion"
    }

    /// Markdown une fois la réflexion figée ; texte brut pendant le streaming (même règle que les réponses : le Markdown
    /// n'est pas recalculé à chaque delta). Voir le paragraphe « Réflexion » de la spec (2026-10-13-zcode-ios-design.md).
    public var showsMarkdown: Bool { state != .streaming }
}

extension TimelineMarker {
    /// Libellé du séparateur ; `nil` pour un marqueur que l'interface web n'affiche pas.
    public var label: String? {
        switch markerType {
        case "compact":
            switch marker["status"]?.stringValue {
            case "running": return "Compression du contexte…"
            case "success": return "Contexte compressé"
            case "noop": return "Contexte déjà à jour"
            case "cancelled": return "Compression interrompue"
            case "failed": return "Échec de la compression du contexte"
            default: return "Compression du contexte"
            }
        case "modelChange":
            guard let to = marker["toModel"]?.stringValue else { return "Changement de modèle" }
            if let from = marker["fromModel"]?.stringValue { return "Modèle : \(from) → \(to)" }
            return "Modèle : \(to)"
        case "forkNotice":
            return "Conversation dérivée d'une autre session"
        case "goalVerify":
            let iteration = marker["iteration"]?.numberValue.map { "Itération \(Int($0)) · " } ?? ""
            switch marker["outcome"]?.stringValue {
            case "pass": return iteration + "Goal atteint"
            case "notSatisfied": return iteration + "Goal non atteint, l'agent continue"
            case "failed" where marker["detail"]?.stringValue == "cancelled": return iteration + "Vérification du Goal interrompue"
            case "failed": return iteration + "Échec de la vérification du Goal"
            default: return iteration + "Vérification du Goal…"
            }
        case "goalSet", "forkCreated", "retryNotice", "checkpointRestored":
            return nil
        case let other?:
            return "Événement ZCode : \(other)"
        case nil:
            return nil
        }
    }
}

public enum ChatLabels {
    /// Sous-titre de la fenêtre de session : hôte et dossier du projet (« MacBook · mon-projet »).
    public static func location(hostName: String, workspace: String) -> String {
        "\(hostName) · \(URL(filePath: workspace).lastPathComponent)"
    }

    public static func queuePause(reason: String?) -> String {
        switch reason {
        case "stopped": "File en pause : tu as arrêté la réponse en cours."
        case "error": "File en pause : la réponse a échoué."
        default: "File en pause."
        }
    }

    /// Message pour une commande que l'hôte n'a pas acceptée.
    static let goalInPlanMode = "Le Goal est indisponible en mode plan : change de mode."
    static let planWithAttachments = "/plan ne prend pas de pièce jointe : retire-la ou envoie un message."
    static let compactQueued = "Compression du contexte mise en file : elle partira après le tour en cours."
    static let compactBusy = "Attends la fin du tour en cours pour compresser le contexte."

    public static func refusal(_ ack: CommandAck) -> String {
        switch ack.reasonCode {
        case "provider.notInRegistry":
            "Modèle indisponible sur l'hôte : choisis-en un autre."
        case "proto.invalidPayload":
            "Message refusé par l'hôte (contenu invalide)."
        case "heldQueueDispositionRequired", "guard.heldQueueConfirmationStale":
            "Des messages attendent dans la file : choisis de la vider ou de la garder."
        case "proto.staleRevision", "proto.staleLogEpoch":
            "La conversation a changé entre-temps : réessaie."
        case "guard.latestAssistantRetryOnly":
            "Seule la dernière réponse peut être relancée."
        case "guard.actionUnavailable":
            "Action indisponible pour l'instant (tour en cours ou demande en attente)."
        case "emptyObjective":
            "Écris l'objectif après /goal."
        case "activeTurn":
            "Attends la fin du tour en cours pour reprendre le Goal."
        case "guard.planGoalMutuallyExclusive":
            goalInPlanMode
        case "sendQueuedNowRequiresRunning":
            "L'agent ne travaille plus : reprends la file pour envoyer ce message."
        case "compactOperationLock", "guard.compactOperationLock":
            "Une compression du contexte est en cours : réessaie quand elle sera finie."
        case "proto.staleTarget":
            "Cette réponse a changé entre-temps : réessaie."
        case "guard.forkAssistantOnly":
            "Seule une réponse de l'agent peut servir de point de départ."
        case "guard.forkTargetNotStable":
            "Cette réponse n'est pas encore figée : attends la fin du tour."
        case "guard.forkTargetAmbiguous":
            "Point de départ ambigu : choisis une autre réponse."
        default:
            "Commande refusée par l'hôte (\(ack.message ?? ack.reasonCode ?? ack.status.rawValue))."
        }
    }

    /// Libellé du bouton d'envoi selon `inputRouting.mode`.
    public static func sendLabel(routing: String) -> String {
        switch routing {
        case "enqueue": "Mettre en file"
        case "guide": "Guider l'agent"
        case "reject": "Envoi impossible"
        default: "Envoyer"
        }
    }

    /// Niveau d'effort lisible (table de l'interface web de ZCode) ; une valeur inconnue reste telle quelle.
    public static func effort(_ level: String) -> String {
        switch level.lowercased() {
        case "disabled", "false", "no", "none", "nothink", "no-think", "no_think", "off": "Désactivé"
        case "enable", "enabled", "on", "true": "Activé"
        case "minimal": "Minimal"
        case "low": "Faible"
        case "medium": "Moyen"
        case "high": "Élevé"
        case "extra-high", "extra_high", "xhigh": "Très élevé"
        case "max": "Maximal"
        case "ultra": "Ultra"
        default: level
        }
    }

    /// Libellé d'une option d'autorisation : l'hôte envoie des libellés anglais que l'interface web traduit d'après leur
    /// texte ; un libellé inconnu (option nouvelle) reste tel quel.
    public static func permissionOption(_ option: PermissionOption) -> String {
        switch option.label {
        case "Allow once": "Autoriser une fois"
        case "Always allow in this project": "Toujours autoriser dans ce projet"
        case "Always allow Computer Use in this project": "Toujours autoriser Computer Use dans ce projet"
        case "Always allow in this session": "Toujours autoriser dans cette session"
        case "Deny": "Refuser"
        case "Refine": "Affiner"
        default: option.label
        }
    }

    /// Provenance d'une demande qui ne vient pas de l'agent principal.
    public static func origin(_ origin: InteractionOrigin?) -> String? {
        guard let origin, origin.kind == "subagent" else { return nil }
        // Agent d'un run de workflow : `description` « persona (site@ordinal) » ; l'hôte 3.15.1 le marque par
        // `agentType: "zcode-workflow"` (tâche 0).
        let description = origin.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if origin.agentType == "zcode-workflow", let description { return "Demande de l'agent \(description)" }
        if let type = origin.agentType { return "Demande du sous-agent \(type)" }
        if let description { return "Demande de l'agent \(description)" }
        return "Demande d'un sous-agent"
    }

    /// Compte à rebours d'une question : à l'échéance l'agent continue sans réponse.
    public static func countdown(seconds: Int) -> String {
        "L'agent continue seul dans \(seconds) s"
    }
}

extension ChatLabels {
    /// Échec d'un téléversement, pour la vignette.
    public static func attachmentFailure(_ error: any Error) -> String {
        if case RPCError.remote(let remote) = error { return "Envoi de la pièce jointe impossible (\(remote.message))." }
        return "Envoi de la pièce jointe impossible : \(ConnectionFailure(error).message)"
    }
}

extension ChatItem {
    /// Texte d'un message ou d'une réponse pour « Copier » / « Partager » (Markdown source) ; `nil` pour les autres
    /// éléments et pour un message fait seulement de pièces jointes.
    public var copyableText: String? {
        let text: String
        switch self {
        case .user(_, let input): text = input.text
        case .assistant(_, let answer): text = answer.text
        default: return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

extension ToolCall {
    /// Commande d'un outil shell (`input.command`), affichée et copiée telle quelle ; `nil` pour les autres outils.
    public var shellCommand: String? {
        guard let command = input?["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return command
    }
}
