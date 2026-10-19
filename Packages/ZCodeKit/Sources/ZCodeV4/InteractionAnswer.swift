import Foundation
import ZCodeWire

/// Réponse à une demande de l'agent (`resolveInteraction.answer`, `command.ts`).
///
/// Autorisation : `optionId` de l'option choisie ; `freeText` = consigne donnée à l'agent avec un refus (ou « Affiner »).
/// Questions (AskUserQuestion, MCP) et approbation du plan : `action` + `content`, forme de l'`ElicitationDialog` de
/// l'interface web, que l'hôte relaie à l'outil. Saisie simple : `freeText` ou `optionId`.
public struct InteractionAnswer: Equatable, Sendable {
    public enum Action: String, Sendable {
        case accept, decline, cancel
    }

    public var optionId: String?
    public var freeText: String?
    public var action: Action?
    public var content: [String: JSONValue]?

    public init(optionId: String? = nil, freeText: String? = nil, action: Action? = nil, content: [String: JSONValue]? = nil) {
        self.optionId = optionId
        self.freeText = freeText
        self.action = action
        self.content = content
    }

    /// Ne pas répondre (question ignorée, plan refusé) : l'outil est refusé.
    public static let decline = InteractionAnswer(action: .decline)

    public var json: JSONValue {
        var answer: [String: JSONValue] = [:]
        if let optionId { answer["optionId"] = .string(optionId) }
        if let freeText { answer["freeText"] = .string(freeText) }
        if let action { answer["action"] = .string(action.rawValue) }
        if let content { answer["content"] = .object(content) }
        return .object(answer)
    }
}
