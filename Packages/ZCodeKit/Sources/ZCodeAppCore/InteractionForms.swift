import Foundation
import ZCodeV4
import ZCodeWire

/// Réponses à une suite de questions (AskUserQuestion, MCP, approbation du plan), règles de l'`ElicitationDialog` de
/// l'interface web de ZCode : une question à la fois, choix simple (passe à la suite) ou multiple, réponse libre.
public struct QuestionForm: Equatable, Sendable {
    struct Draft: Equatable, Sendable {
        var selected: [String] = []
        var custom = ""
    }

    public let questions: [UserInputQuestion]
    private var drafts: [Draft]
    public private(set) var index = 0

    public init(questions: [UserInputQuestion]) {
        self.questions = questions
        drafts = Array(repeating: Draft(), count: questions.count)
    }

    public var current: UserInputQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    public var isLast: Bool { index >= questions.count - 1 }
    public var canGoBack: Bool { index > 0 }

    public var customAnswer: String { drafts.indices.contains(index) ? drafts[index].custom : "" }

    public func isSelected(_ value: String) -> Bool {
        drafts.indices.contains(index) && drafts[index].selected.contains(value)
    }

    /// Choix d'une option de la question courante. Choix simple : la réponse est remplacée (réponse libre comprise) et le
    /// formulaire passe à la question suivante ; rend `true` s'il n'y en a plus (il faut alors envoyer). Choix multiple :
    /// l'option est cochée ou décochée.
    public mutating func choose(_ value: String) -> Bool {
        guard let question = current else { return false }
        if question.multiSelect == true {
            if let position = drafts[index].selected.firstIndex(of: value) {
                drafts[index].selected.remove(at: position)
            } else {
                drafts[index].selected.append(value)
            }
            return false
        }
        drafts[index] = Draft(selected: [value], custom: "")
        if isLast { return true }
        index += 1
        return false
    }

    /// Réponse libre ; en choix simple elle remplace l'option choisie.
    public mutating func setCustom(_ text: String) {
        guard let question = current else { return }
        if question.multiSelect != true { drafts[index].selected = [] }
        drafts[index].custom = text
    }

    public mutating func next() {
        if !isLast { index += 1 }
    }

    public mutating func back() {
        if canGoBack { index -= 1 }
    }

    /// Réponses données à la question `position` : options choisies (dans l'ordre), puis la réponse libre sans blancs.
    public func answers(at position: Int) -> [String] {
        guard drafts.indices.contains(position) else { return [] }
        let custom = drafts[position].custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return drafts[position].selected + (custom.isEmpty ? [] : [custom])
    }

    /// `content` de la réponse (`buildElicitationResponseContent`) : `answers` indexé par le texte de la question
    /// (réponses jointes par « , »), `answer_N` (tableau en choix multiple), `answer` s'il n'y a qu'une question. Une
    /// question sans réponse n'apparaît pas : l'agent continue à son jugement.
    public var content: [String: JSONValue] {
        var answers: [String: JSONValue] = [:]
        var content: [String: JSONValue] = [:]
        for (position, question) in questions.enumerated() {
            let values = self.answers(at: position)
            guard let first = values.first else { continue }
            answers[question.question] = .string(values.joined(separator: ", "))
            let value: JSONValue = question.multiSelect == true ? .array(values.map(JSONValue.string)) : .string(first)
            content["answer_\(position)"] = value
            if questions.count == 1 { content["answer"] = value }
        }
        content["answers"] = .object(answers)
        return content
    }

    public var answer: InteractionAnswer { InteractionAnswer(action: .accept, content: content) }
}

/// Approbation du plan (ExitPlanMode), posée par l'hôte comme une question à une option `approve`.
public enum PlanApproval {
    public static let approveValue = "approve"

    /// Approuver : l'agent sort du mode plan et implémente. Une réponse vide vaudrait refus côté hôte : on répond
    /// explicitement `approve` (règle `continueOrSubmit` de l'interface web).
    public static func approve(_ request: UserInputRequest) -> InteractionAnswer {
        var form = QuestionForm(questions: request.questions ?? [])
        guard form.current?.options.contains(where: { $0.value == approveValue }) == true else {
            return InteractionAnswer(action: .accept, content: ["answer": .string(approveValue)])
        }
        _ = form.choose(approveValue)
        return form.answer
    }

    /// Demander des changements : l'agent reste en mode plan et reçoit la consigne ; `nil` si elle est vide.
    public static func requestChanges(_ feedback: String, to request: UserInputRequest) -> InteractionAnswer? {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var form = QuestionForm(questions: request.questions ?? [])
        guard form.current != nil else { return InteractionAnswer(action: .accept, content: ["answer": .string(text)]) }
        form.setCustom(text)
        return form.answer
    }
}

/// Demande d'autorisation telle que l'app la présente (règles du `PermissionDialog` de l'interface web).
public struct PermissionPrompt: Equatable, Sendable {
    /// « Affiner » d'un workflow : ce n'est pas un bouton mais la ligne de consigne.
    public static let refineOptionId = "workflowRefine"
    /// Plafond d'une consigne (`MAX_PERMISSION_FEEDBACK_CHARS`).
    public static let maxFeedbackLength = 4_096

    public let request: PermissionRequest

    public init(_ request: PermissionRequest) {
        self.request = request
    }

    /// Options en boutons, dans l'ordre du serveur ; une option inconnue de l'app est gardée telle quelle.
    public var buttons: [PermissionOption] { request.options.filter { $0.optionId != Self.refineOptionId } }

    /// Option qui porte une consigne écrite : « Affiner », sinon le refus si l'hôte accepte du texte libre.
    public var feedbackOption: PermissionOption? {
        request.options.first { $0.optionId == Self.refineOptionId }
            ?? (request.freeText == true ? request.options.first { $0.kind == .deny } : nil)
    }

    /// Détail lisible : la commande telle quelle si c'en est une, sinon les arguments en JSON ; `nil` s'il n'y a rien.
    public var detailText: String? {
        guard let detail = request.detail, detail != .null, detail != .object([:]) else { return nil }
        if let command = detail["command"]?.stringValue { return command }
        return detail.prettyText
    }

    public func answer(_ option: PermissionOption) -> InteractionAnswer {
        InteractionAnswer(optionId: option.optionId)
    }

    /// Bouton touché alors qu'une consigne est tapée : elle accompagne le refus qui la porte (règle `respondWithOption`
    /// de l'interface web) ; avec « Affiner », ou pour une autre option, elle n'est pas envoyée.
    public func answer(_ option: PermissionOption, feedback: String) -> InteractionAnswer {
        guard option.kind == .deny, feedbackOption?.optionId == option.optionId,
              let withFeedback = answer(withFeedback: feedback) else { return answer(option) }
        return withFeedback
    }

    /// Refus (ou « Affiner ») accompagné d'une consigne pour l'agent ; `nil` si la consigne est vide ou si l'hôte n'en
    /// accepte pas.
    public func answer(withFeedback feedback: String) -> InteractionAnswer? {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = feedbackOption, !text.isEmpty else { return nil }
        return InteractionAnswer(optionId: option.optionId, freeText: String(text.prefix(Self.maxFeedbackLength)))
    }
}

extension InteractionAnswer {
    /// Saisie libre d'une demande sans questions ; `nil` si elle est vide.
    public static func text(_ text: String) -> InteractionAnswer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : InteractionAnswer(freeText: trimmed)
    }

    public static func choice(_ choice: UserInputChoice) -> InteractionAnswer {
        InteractionAnswer(optionId: choice.optionId)
    }
}
