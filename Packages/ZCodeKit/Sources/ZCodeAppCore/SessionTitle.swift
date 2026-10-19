import Foundation

/// Titre d'une session saisi dans l'app. L'hôte accepte tout (`renameSession {title: string}`) : c'est l'app qui
/// évite d'envoyer un titre vide ou inchangé.
public enum SessionTitle {
    /// Titre à envoyer : sans espaces autour, retours à la ligne remplacés par des espaces ; `nil` s'il est vide ou
    /// identique au titre actuel.
    public static func normalized(_ typed: String, current: String?) -> String? {
        let title = typed.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != current else { return nil }
        return title
    }
}
