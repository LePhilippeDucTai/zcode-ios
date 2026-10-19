import Foundation

/// Texte envoyé pour une skill ou un sous-agent choisi dans le panneau « / » (`mentionMarkdown.ts` de ZCode Web).
public enum SlashMarkdown {
    /// `buildSkillMentionMarkdown` : `[$nom](chemin)`, chemin du catalogue tel quel ; `$nom` seul sans chemin.
    public static func skill(name: String, path: String?) -> String {
        guard let path, !path.isEmpty else { return "$" + name }
        return "[\(escapeLabel("$" + name))](\(escapeDestination(destination(path))))"
    }

    /// `buildSubagentMentionMarkdown`.
    public static func subagent(name: String) -> String { "@" + name }

    /// `normalizeMarkdownDestination` : un chemin absolu, relatif explicite, une ancre ou une adresse restent tels quels ;
    /// un chemin nu prend « ./ » (sinon `foo/bar` serait lu comme un protocole `foo:`).
    static func destination(_ path: String) -> String {
        if ["/", "./", "../", "#"].contains(where: path.hasPrefix) || path.firstMatch(of: /^[a-zA-Z][a-zA-Z\d+.\-]*:/) != nil {
            return path
        }
        return "./" + path
    }

    private static func escapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeDestination(_ destination: String) -> String {
        destination.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ">", with: "\\>")
    }
}
