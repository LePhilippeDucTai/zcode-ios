import Foundation
import ZCodeWire

/// Révision et époque de l'état sur lequel une commande CAS a été décidée.
public struct CommandBase: Equatable, Sendable {
    public let revision: Int
    public let logEpoch: String

    public init(revision: Int, logEpoch: String) {
        self.revision = revision
        self.logEpoch = logEpoch
    }
}

extension ConversationSnapshot {
    public var commandBase: CommandBase { CommandBase(revision: revision, logEpoch: logEpoch) }
}

/// Erreur de programmation : une commande CAS ou ciblant une ligne construite sans base.
public enum CommandBuildError: Error, Equatable, Sendable {
    case missingBaseRevision(CommandType)
    case missingBaseLogEpoch(CommandType)
}

/// Fabrique des enveloppes de commande (`commandFactory.ts`).
public struct CommandBuilder: Sendable {
    public enum Delivery: String, Sendable {
        case startNow, queue, guide
    }

    /// Réponse au choix demandé quand une file en pause attend (`inputRouting.mode == "choice"`).
    public struct HeldQueueChoice: Equatable, Sendable {
        public enum Disposition: String, Sendable {
            case clearQueueAndSend, keepQueueAndSend
        }

        public let disposition: Disposition
        /// Éléments de la file vus par l'utilisateur : le serveur refuse (`guard.heldQueueConfirmationStale`) si
        /// la file a changé entre-temps.
        public let expectedItemIds: [String]

        public init(_ disposition: Disposition, expectedItemIds: [String]) {
            self.disposition = disposition
            self.expectedItemIds = expectedItemIds
        }
    }

    public let clientId: String
    private let clock: @Sendable () -> Date

    public init(clientId: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clientId = clientId
        self.clock = clock
    }

    /// Construction générique ; refuse une commande CAS sans `base`.
    public func envelope(
        _ type: CommandType, sessionId: String?, payload: [String: JSONValue], base: CommandBase? = nil
    ) throws(CommandBuildError) -> CommandEnvelope {
        if base == nil {
            if CommandType.requiringBaseRevision.contains(type) { throw .missingBaseRevision(type) }
            if CommandType.targetingRows.contains(type) { throw .missingBaseLogEpoch(type) }
        }
        return make(type, sessionId: sessionId, payload: payload, base: base)
    }

    /// `mode` / `planEnabled` : réglages demandés pour la session neuve (`createSession.config`). Absents, rien n'est
    /// envoyé et l'hôte applique son défaut (le snapshot affiche alors `build`).
    public func createSession(workspaceId: String, mode: String? = nil, planEnabled: Bool? = nil) -> CommandEnvelope {
        var payload: [String: JSONValue] = ["workspaceId": .string(workspaceId)]
        var config: [String: JSONValue] = [:]
        if let mode { config["mode"] = .string(mode) }
        if let planEnabled { config["planEnabled"] = .bool(planEnabled) }
        if !config.isEmpty { payload["config"] = .object(config) }
        return make(.createSession, sessionId: nil, payload: payload)
    }

    /// Sans `delivery`, l'hôte choisit d'après `inputRouting` (démarrer, mettre en file ou guider le tour en cours) :
    /// `startNow` explicite interromprait le tour en cours.
    public func sendText(
        sessionId: String, text: String, delivery: Delivery? = nil,
        modelSelection: ModelSelection? = nil, mode: String? = nil, planEnabled: Bool? = nil,
        heldQueue: HeldQueueChoice? = nil, attachments: [AttachmentRef] = []
    ) -> CommandEnvelope {
        var payload: [String: JSONValue] = [
            "text": .string(text),
            "inputOrigin": .string("mobile"),
        ]
        if let delivery { payload["requestedDelivery"] = .string(delivery.rawValue) }
        if let modelSelection { payload["modelSelection"] = try? V4JSON.encode(modelSelection) }
        if let mode { payload["mode"] = .string(mode) }
        if let planEnabled { payload["planEnabled"] = .bool(planEnabled) }
        if let heldQueue {
            payload["heldQueueDisposition"] = .string(heldQueue.disposition.rawValue)
            payload["expectedHeldQueueItemIds"] = .array(heldQueue.expectedItemIds.map(JSONValue.string))
        }
        if !attachments.isEmpty { payload["attachments"] = .array(attachments.map(\.json)) }
        return make(.sendText, sessionId: sessionId, payload: payload)
    }

    /// Lance (ou remplace) le Goal. `objective` seul, sans « /goal » : l'hôte le prend tel quel ; `displayText` = texte
    /// saisi, montré dans la conversation. Pas CAS ; occupé, l'hôte le met en file.
    public func sendGoal(
        sessionId: String, objective: String, displayText: String?,
        modelSelection: ModelSelection? = nil, mode: String? = nil, planEnabled: Bool? = nil,
        heldQueue: HeldQueueChoice? = nil
    ) -> CommandEnvelope {
        var payload: [String: JSONValue] = ["text": .string(objective)]
        if let displayText { payload["displayText"] = .string(displayText) }
        if let modelSelection { payload["modelSelection"] = try? V4JSON.encode(modelSelection) }
        if let mode { payload["mode"] = .string(mode) }
        if let planEnabled { payload["planEnabled"] = .bool(planEnabled) }
        if let heldQueue {
            payload["heldQueueDisposition"] = .string(heldQueue.disposition.rawValue)
            payload["expectedHeldQueueItemIds"] = .array(heldQueue.expectedItemIds.map(JSONValue.string))
        }
        return make(.sendGoalCommand, sessionId: sessionId, payload: payload)
    }

    public func stop(sessionId: String, expectedForegroundExecutionId: String? = nil) -> CommandEnvelope {
        var payload: [String: JSONValue] = [:]
        if let expectedForegroundExecutionId { payload["expectedForegroundExecutionId"] = .string(expectedForegroundExecutionId) }
        return make(.stop, sessionId: sessionId, payload: payload)
    }

    /// Coupe la conversation après le message du tour et rejoue la réponse (`target` = la ligne `assistantText` marquée
    /// `canRetry`).
    public func retryTurn(sessionId: String, target: RowTarget, base: CommandBase) -> CommandEnvelope {
        make(.retryTurn, sessionId: sessionId, payload: ["target": target.json], base: base)
    }

    /// Nouvelle session qui reprend la conversation jusqu'à cette réponse (`target` = ligne `assistantText` marquée
    /// `canFork`) ; l'accusé porte `result.sessionId` de la session enfant.
    public func forkAssistant(sessionId: String, target: RowTarget, base: CommandBase) -> CommandEnvelope {
        make(.forkAssistant, sessionId: sessionId, payload: ["target": target.json], base: base)
    }

    public func compact(sessionId: String) -> CommandEnvelope {
        make(.compact, sessionId: sessionId, payload: [:])
    }

    public func resolveInteraction(sessionId: String, interactionId: String, answer: InteractionAnswer) -> CommandEnvelope {
        make(.resolveInteraction, sessionId: sessionId,
             payload: ["interactionId": .string(interactionId), "answer": answer.json])
    }

    /// Première action sur une question à compte à rebours : l'agent ne continue plus seul à la fin du délai.
    public func snoozeAutoResolution(sessionId: String, interactionId: String) -> CommandEnvelope {
        make(.snoozeInteractionAutoResolution, sessionId: sessionId, payload: ["interactionId": .string(interactionId)])
    }

    public func switchModelConfig(sessionId: String, provider: String, model: String, thought: String, base: CommandBase) -> CommandEnvelope {
        make(.switchModelConfig, sessionId: sessionId,
             payload: ["provider": .string(provider), "model": .string(model), "thought": .string(thought)], base: base)
    }

    public func switchCollaborationMode(sessionId: String, mode: String, base: CommandBase) -> CommandEnvelope {
        make(.switchCollaborationMode, sessionId: sessionId, payload: ["mode": .string(mode)], base: base)
    }

    public func setFollowupMode(sessionId: String, mode: String, base: CommandBase) -> CommandEnvelope {
        make(.setFollowupMode, sessionId: sessionId, payload: ["mode": .string(mode)], base: base)
    }

    public func pauseGoal(sessionId: String, base: CommandBase) -> CommandEnvelope {
        make(.pauseGoal, sessionId: sessionId, payload: [:], base: base)
    }

    public func resumeGoal(sessionId: String, base: CommandBase) -> CommandEnvelope {
        make(.resumeGoal, sessionId: sessionId, payload: [:], base: base)
    }

    public func deleteQueueItem(sessionId: String, queueItemId: String, base: CommandBase) -> CommandEnvelope {
        make(.deleteQueueItem, sessionId: sessionId, payload: ["queueItemId": .string(queueItemId)], base: base)
    }

    /// Envoie tout de suite un élément de la file (guide le tour en cours) ; exige une session en cours.
    public func sendQueuedNow(sessionId: String, queueItemId: String, base: CommandBase) -> CommandEnvelope {
        make(.sendQueuedNow, sessionId: sessionId, payload: ["queueItemId": .string(queueItemId)], base: base)
    }

    /// `true` : la file reprend (après un arrêt qui l'a mise en pause).
    public func setAutoDrain(sessionId: String, autoDrain: Bool, base: CommandBase) -> CommandEnvelope {
        make(.setAutoDrain, sessionId: sessionId, payload: ["autoDrain": .bool(autoDrain)], base: base)
    }

    public func renameSession(sessionId: String, title: String) -> CommandEnvelope {
        make(.renameSession, sessionId: sessionId, payload: ["title": .string(title)])
    }

    public func deleteSession(sessionId: String) -> CommandEnvelope {
        make(.deleteSession, sessionId: sessionId, payload: [:])
    }

    /// Lance un workflow enregistré (`args` omis s'il est `nil` ou vide) ; sans CAS.
    public func startSavedWorkflow(
        sessionId: String, name: String, scope: SavedWorkflowScope?, args: [String: JSONValue]?
    ) -> CommandEnvelope {
        var payload: [String: JSONValue] = ["name": .string(name)]
        if let scope { payload["scope"] = .string(scope.rawValue) }
        if let args, !args.isEmpty { payload["args"] = .object(args) }
        return make(.startSavedWorkflow, sessionId: sessionId, payload: payload)
    }

    /// Annule un travail d'arrière-plan (un run de workflow : `workId` = `runId`).
    public func cancelBackgroundWork(sessionId: String, workId: String) -> CommandEnvelope {
        make(.cancelBackgroundWork, sessionId: sessionId, payload: ["workId": .string(workId)])
    }

    private func make(_ type: CommandType, sessionId: String?, payload: [String: JSONValue], base: CommandBase? = nil) -> CommandEnvelope {
        let now = clock()
        return CommandEnvelope(
            commandId: UUIDv7.make(at: now),
            clientId: clientId,
            sessionId: sessionId,
            baseRevision: base?.revision,
            baseLogEpoch: base?.logEpoch,
            type: type,
            payload: .object(payload),
            issuedAt: Int64((now.timeIntervalSince1970 * 1000).rounded())
        )
    }
}
