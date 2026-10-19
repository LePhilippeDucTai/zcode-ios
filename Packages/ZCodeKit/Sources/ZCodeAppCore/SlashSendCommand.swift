import Foundation

/// Commandes traitées par l'app à l'envoi, comme le web (`parseV4VisibleSlashCommand`) ; `/goal` et `/target` restent à
/// `GoalCommand`, tout le reste (`/workflow`, `/init`, commandes personnalisées) part tel quel et l'hôte le développe.
public enum SlashSendCommand: Equatable, Sendable {
    /// `/plan [tâche]` : mode plan, puis la tâche seule (sans tâche, rien n'est envoyé).
    case plan(task: String)
    /// `/plan` avec une pièce jointe : refusé.
    case planWithAttachments
    /// `/compact` ou `/compress` sans pièce jointe ; le texte qui suit est ignoré.
    case compact

    public static func parse(_ text: String, hasAttachments: Bool) -> SlashSendCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        let task = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "plan": return hasAttachments ? .planWithAttachments : .plan(task: task)
        case "compact", "compress": return hasAttachments ? nil : .compact
        default: return nil
        }
    }
}
