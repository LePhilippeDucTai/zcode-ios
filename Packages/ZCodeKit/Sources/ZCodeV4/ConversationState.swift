import Foundation
import ZCodeWire

public struct SessionPhase: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let draft = SessionPhase(rawValue: "draft")
    public static let prewarming = SessionPhase(rawValue: "prewarming")
    public static let running = SessionPhase(rawValue: "running")
    public static let completedSuccess = SessionPhase(rawValue: "completedSuccess")
    public static let completedInterrupted = SessionPhase(rawValue: "completedInterrupted")
    public static let error = SessionPhase(rawValue: "error")
}

public struct ActiveWork: Decodable, Equatable, Sendable {
    public let kind: String
    /// À renvoyer dans `stop` pour ne pas interrompre une exécution suivante par erreur.
    public let foregroundExecutionId: String?
    public let sourceCommandId: String?
}

public struct SessionError: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool?
    public let detail: String?
}

public struct SessionControl: Decodable, Equatable, Sendable {
    public let phase: SessionPhase
    public let sessionEnded: Bool?
    public let canStop: Bool?
    public let stopState: String?
    public let activeWorks: [ActiveWork]?
    public let lastError: SessionError?

    /// Un tour est en cours (envoyer = guider ou mettre en file selon `inputRouting`).
    public var isBusy: Bool { phase == .running || phase == .prewarming }
}

/// Choix de modèle (`model-selection.ts`) ; `options.reasoningLevel` est exigé par certains fournisseurs.
public struct ModelSelection: Codable, Equatable, Sendable {
    public struct Options: Codable, Equatable, Sendable {
        public var reasoningLevel: String?

        public init(reasoningLevel: String? = nil) {
            self.reasoningLevel = reasoningLevel
        }
    }

    public var providerId: String
    public var modelId: String
    public var options: Options?

    public init(providerId: String, modelId: String, reasoningLevel: String? = nil) {
        self.providerId = providerId
        self.modelId = modelId
        self.options = reasoningLevel.map { Options(reasoningLevel: $0) }
    }
}

public struct SessionConfig: Decodable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let thought: String
    /// Niveaux d'effort proposés par le serveur (jamais codés en dur dans l'app).
    public let thoughtLevels: [String]?
    public let followupMode: String?
    public let mode: String?
    public let planEnabled: Bool?
    public let modelSelection: ModelSelection?
}

public struct SessionMeta: Decodable, Equatable, Sendable {
    public let title: String
    public let titleSource: String?
}

public struct ActionAvailability: Decodable, Equatable, Sendable {
    public let allowed: Bool
    public let reasonCode: String?
}

public struct InputRouting: Decodable, Equatable, Sendable {
    /// `startNow`, `enqueue`, `guide`, `reject` ou `choice`.
    public let mode: String
    public let reasonCode: String?
}

public struct GoalStatus: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let active = GoalStatus(rawValue: "active")
    public static let paused = GoalStatus(rawValue: "paused")
    public static let verifying = GoalStatus(rawValue: "verifying")
    public static let verified = GoalStatus(rawValue: "verified")
    public static let notSatisfied = GoalStatus(rawValue: "notSatisfied")
    public static let failed = GoalStatus(rawValue: "failed")
}

/// Résultat d'une vérification du Goal (`running` : seulement dans un marqueur de chronologie, vérification en cours).
public struct GoalOutcome: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let pass = GoalOutcome(rawValue: "pass")
    public static let notSatisfied = GoalOutcome(rawValue: "notSatisfied")
    public static let failed = GoalOutcome(rawValue: "failed")
    public static let running = GoalOutcome(rawValue: "running")
}

/// Vérification d'une itération par le modèle de la session (20 au plus sont gardées par l'hôte).
public struct GoalVerification: Decodable, Equatable, Sendable {
    public let iteration: Int
    public let outcome: GoalOutcome
    /// Horodatage en ms.
    public let at: Double
    /// Ligne de chronologie à laquelle la vérification se rattache.
    public let anchorRowId: Int?
    public let reason: String?
    /// Ce que l'agent fera ensuite : titre de l'itération suivante.
    public let nextAction: String?

    private enum CodingKeys: String, CodingKey { case iteration, outcome, at, anchorRowId, reason, nextAction }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iteration = try container.decode(Int.self, forKey: .iteration)
        outcome = GoalOutcome(rawValue: try container.decode(String.self, forKey: .outcome))
        at = try container.decodeIfPresent(Double.self, forKey: .at) ?? 0
        anchorRowId = try container.decodeIfPresent(Int.self, forKey: .anchorRowId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
    }
}

/// Tâche (TodoWrite) projetée dans une itération du Goal.
public struct GoalPlanItem: Decodable, Equatable, Sendable {
    public let id: String
    public let content: String
    /// `pending`, `inProgress` ou `completed`.
    public let status: String

    public var isCompleted: Bool { status == "completed" }
}

public struct GoalIteration: Decodable, Equatable, Sendable {
    public let iteration: Int
    public let items: [GoalPlanItem]
    public let updatedAt: Double?

    private enum CodingKeys: String, CodingKey { case iteration, items, updatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iteration = try container.decode(Int.self, forKey: .iteration)
        items = try container.decodeIfPresent([GoalPlanItem].self, forKey: .items) ?? []
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
}

/// Goal de la session (`snapshot.goal`) : seuls `objective` et `status` sont exigés, le reste prend les valeurs par
/// défaut du schéma de ZCode. Ni budget ni nombre maximal d'itérations : la boucle continue jusqu'à réussite ou pause.
public struct GoalState: Decodable, Equatable, Sendable {
    public let targetId: String
    public let objective: String
    /// Titre court généré par le modèle.
    public let summaryTitle: String?
    /// Temps de travail cumulé, sans la course en cours.
    public let timeUsedSeconds: Int
    /// Début (ms) de la course en cours : à ajouter à `timeUsedSeconds` pour la durée en direct.
    public let activeRunStartedAtMs: Double?
    public let status: GoalStatus
    public let iteration: Int
    public let verifications: [GoalVerification]
    public let iterations: [GoalIteration]

    private enum CodingKeys: String, CodingKey {
        case targetId, objective, summaryTitle, timeUsedSeconds, activeRunStartedAtMs, status, iteration, verifications, iterations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetId = try container.decodeIfPresent(String.self, forKey: .targetId) ?? ""
        objective = try container.decode(String.self, forKey: .objective)
        summaryTitle = try container.decodeIfPresent(String.self, forKey: .summaryTitle)
        timeUsedSeconds = try container.decodeIfPresent(Int.self, forKey: .timeUsedSeconds) ?? 0
        activeRunStartedAtMs = try container.decodeIfPresent(Double.self, forKey: .activeRunStartedAtMs)
        status = GoalStatus(rawValue: try container.decode(String.self, forKey: .status))
        iteration = try container.decodeIfPresent(Int.self, forKey: .iteration) ?? 0
        verifications = try container.decodeIfPresent([GoalVerification].self, forKey: .verifications) ?? []
        iterations = try container.decodeIfPresent([GoalIteration].self, forKey: .iterations) ?? []
    }
}

public struct QueueItem: Decodable, Equatable, Sendable {
    public struct Delivery: Decodable, Equatable, Sendable {
        public let requested: String?
        public let admitted: String?
    }

    public struct Dispatch: Decodable, Equatable, Sendable {
        public let state: String?
    }

    public let queueItemId: String
    public let kind: String?
    public let text: String
    public let delivery: Delivery?
    public let dispatch: Dispatch?

    private enum CodingKeys: String, CodingKey {
        case queueItemId, kind, text, delivery, dispatch
    }

    /// Tolérant : `delivery` ou `dispatch` d'un type inattendu valent `nil` au lieu de faire perdre l'élément
    /// (la file attendue d'une question « vider / garder » serait sinon incomplète).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queueItemId = try container.decode(String.self, forKey: .queueItemId)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        delivery = try? container.decodeIfPresent(Delivery.self, forKey: .delivery)
        dispatch = try? container.decodeIfPresent(Dispatch.self, forKey: .dispatch)
    }

    /// Admis pour guider le tour en cours : affiché à la fin de la conversation, pas dans la file.
    public var isGuide: Bool { delivery?.admitted == "guide" }

    /// Déjà pris en charge par l'hôte (`reserved`, `promoting`) : ni suppression ni envoi immédiat.
    public var isLocked: Bool { (dispatch?.state ?? "queued") != "queued" }
}

public struct QueueState: Equatable, Sendable {
    public let items: [QueueItem]
    public let autoDrain: Bool?
    public let pauseReason: String?

    public init(items: [QueueItem], autoDrain: Bool?, pauseReason: String?) {
        self.items = items
        self.autoDrain = autoDrain
        self.pauseReason = pauseReason
    }
}

public struct ContextUsage: Decodable, Equatable, Sendable {
    public let usedTokens: Double
    public let maxTokens: Double
}

public struct InteractionKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let permission = InteractionKind(rawValue: "permission")
    public static let userInput = InteractionKind(rawValue: "userInput")
    public static let workspaceHookReview = InteractionKind(rawValue: "workspaceHookReview")
}

public struct PermissionOptionKind: OpenEnum {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let allowOnce = PermissionOptionKind(rawValue: "allowOnce")
    public static let allowAlways = PermissionOptionKind(rawValue: "allowAlways")
    public static let deny = PermissionOptionKind(rawValue: "deny")
    public static let custom = PermissionOptionKind(rawValue: "custom")
}

public struct PermissionOption: Decodable, Equatable, Sendable {
    public let optionId: String
    public let label: String
    public let kind: PermissionOptionKind
}

public struct PermissionRequest: Decodable, Equatable, Sendable {
    public let toolCallId: String?
    public let toolName: String
    public let summary: String
    /// Arguments de l'outil (commande, chemin, contenu…), forme propre à chaque outil : affichage générique.
    public let detail: JSONValue?
    /// Options fournies par le serveur (libellés compris) : l'app les affiche dans l'ordre reçu. `fullAccessOption`
    /// (accès total à la session) n'est volontairement pas lue : hors périmètre de l'app.
    public let options: [PermissionOption]
    public let freeText: Bool?
}

public struct UserInputChoice: Decodable, Equatable, Sendable {
    public let optionId: String
    public let label: String
}

public struct UserInputQuestionOption: Decodable, Equatable, Sendable {
    public let value: String
    public let label: String
    public let description: String?
    public let preview: String?
}

public struct UserInputQuestion: Decodable, Equatable, Sendable {
    public let question: String
    public let header: String?
    public let options: [UserInputQuestionOption]
    public let multiSelect: Bool?
}

public struct UserInputRequest: Decodable, Equatable, Sendable {
    public let prompt: String
    public let freeText: Bool?
    public let options: [UserInputChoice]?
    public let questions: [UserInputQuestion]?
    public let toolName: String?
    public let toolCallId: String?
    public let sensitive: Bool?
    /// Arguments bruts de l'outil (ExitPlanMode : `plan`).
    public let input: JSONValue?
    /// Ex. `{ interaction: "plan_approval", toolName: "ExitPlanMode" }`.
    public let schema: JSONValue?

    /// Approbation du plan (ExitPlanMode), posée comme une question à une option `approve` (règle de l'interface web).
    public var isPlanApproval: Bool {
        schema?["interaction"]?.stringValue == "plan_approval" && schema?["toolName"]?.stringValue == "ExitPlanMode"
    }

    /// Texte du plan à approuver (`input.plan`), `nil` s'il est absent ou vide.
    public var planText: String? {
        guard isPlanApproval,
              let plan = input?["plan"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty
        else { return nil }
        return plan
    }
}

/// Compte à rebours d'une question (AskUserQuestion) au bout duquel l'agent continue seul
/// (`interactionAutoResolutionSchema`) ; horodatages en ms.
public struct InteractionAutoResolution: Decodable, Equatable, Sendable {
    /// `hiddenGrace`, `visibleCountdown` ou `snoozed`.
    public let state: String
    public let deadlineAt: Double?

    public var isSnoozed: Bool { state == "snoozed" }

    /// Secondes restantes, seulement pendant la dernière minute (règle de l'interface web) ; `nil` sinon.
    public func countdownSeconds(now: Date) -> Int? {
        guard !isSnoozed, let deadlineAt else { return nil }
        let remaining = deadlineAt - now.timeIntervalSince1970 * 1000
        guard remaining > 0, remaining < 60_000 else { return nil }
        return max(1, Int((remaining / 1000).rounded(.down)))
    }
}

/// Demande relayée depuis un sous-agent (`zcodeInteractionRequestOriginSchema`).
public struct InteractionOrigin: Decodable, Equatable, Sendable {
    public let kind: String
    public let agentType: String?
    public let description: String?
}

/// Approbation ou question bloquante, à résoudre par `resolveInteraction`.
public struct PendingInteraction: Equatable, Sendable, Identifiable {
    public enum Payload: Equatable, Sendable {
        case permission(PermissionRequest)
        case userInput(UserInputRequest)
        /// Type non géré nativement (ex. `workspaceHookReview`) ou contenu illisible : renvoyer vers la vue web.
        case unsupported
    }

    public let interactionId: String
    public let kind: InteractionKind
    public let anchorRowId: Int?
    /// Horodatage du serveur (ms).
    public let createdAt: Double?
    /// Lu à part : illisible, il vaut `nil` sans faire perdre la demande.
    public let autoResolution: InteractionAutoResolution?
    public let origin: InteractionOrigin?
    public let payload: Payload
    public let raw: JSONValue

    public var id: String { interactionId }

    public init?(json: JSONValue) {
        guard let interactionId = json["interactionId"]?.stringValue else { return nil }
        let kind = InteractionKind(rawValue: json["kind"]?.stringValue ?? json["payload"]?["kind"]?.stringValue ?? "")
        self.interactionId = interactionId
        self.kind = kind
        self.anchorRowId = V4JSON.integer(json["anchorRowId"])
        self.createdAt = json["createdAt"]?.numberValue
        self.autoResolution = json["autoResolution"].flatMap { try? V4JSON.decode(InteractionAutoResolution.self, from: $0) }
        self.origin = json["payload"]?["origin"].flatMap { try? V4JSON.decode(InteractionOrigin.self, from: $0) }
        self.raw = json
        let payload = json["payload"] ?? .null
        if kind == .permission, let request = try? V4JSON.decode(PermissionRequest.self, from: payload) {
            self.payload = .permission(request)
        } else if kind == .userInput, let request = try? V4JSON.decode(UserInputRequest.self, from: payload) {
            self.payload = .userInput(request)
        } else {
            self.payload = .unsupported
        }
    }
}
