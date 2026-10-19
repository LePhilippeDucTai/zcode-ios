import Foundation

/// `/goal …` tapé dans le composeur, analysé comme l'interface web (`v4/slashCommands.ts`) : l'hôte prend le texte reçu
/// tel quel comme objectif, c'est donc à l'app de retirer la commande.
public enum GoalCommand: Equatable, Sendable {
    case set(objective: String)
    case resume
    /// `pause`, `clear` ou `show` : sans équivalent dans le protocole V4 (ou déjà à l'écran).
    case unsupported(String)
    case empty

    /// `nil` : le texte n'est pas une commande Goal (il part comme un message). Comme le web : commande et premier mot
    /// sans tenir compte de la casse, premier mot = action (`/goal pause stp` ne lance pas un Goal « pause stp »).
    public static func parse(_ text: String) -> GoalCommand? {
        let lowered = text.lowercased()
        guard let command = ["/goal", "/target"].first(where: { lowered.hasPrefix($0) }) else { return nil }
        let rest = text.dropFirst(command.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        let argument = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return .empty }
        let action = argument.prefix { !$0.isWhitespace }.lowercased()
        switch action {
        case "resume": return .resume
        case "pause", "clear", "show": return .unsupported(action)
        case "replace":
            let objective = argument.dropFirst(action.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return objective.isEmpty ? .empty : .set(objective: objective)
        default: return .set(objective: argument)
        }
    }

    /// Message affiché quand la commande ne part pas.
    var refusal: String? {
        switch self {
        case .empty: "Écris l'objectif après /goal."
        case .unsupported("pause"): "Mets le Goal en pause depuis le bandeau."
        case .unsupported("clear"): "ZCode ne permet pas d'effacer un Goal : mets-le en pause, ou lance un nouvel objectif."
        case .unsupported: "Le Goal est affiché en haut de la conversation."
        case .set, .resume: nil
        }
    }
}
