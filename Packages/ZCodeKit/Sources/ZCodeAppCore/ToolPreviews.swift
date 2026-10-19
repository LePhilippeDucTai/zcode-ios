import Foundation
import ZCodeV4
import ZCodeWire

/// Aperçu d'une demande d'autorisation d'après les arguments de l'outil (`detail`) : l'hôte ne fournit ni diff ni
/// aperçu pour Edit, Write ou Bash (ZCode 3.15.1) ; l'interface web les calcule aussi de son côté.
public enum PermissionPreview: Equatable, Sendable {
    case diff(FileDiff)
    case command(String, description: String?)
    case fetch(url: String, prompt: String?)
    case text(String)
}

extension PermissionPrompt {
    /// `nil` : rien de plus que le résumé (outil MCP — le web n'en montre pas les arguments bruts — ou détail vide).
    public var preview: PermissionPreview? {
        let detail = request.detail
        if let diff = ToolDiffs.fromArguments(toolName: request.toolName, detail) { return .diff(diff) }
        if let command = detail?["command"]?.stringValue {
            return .command(command, description: detail?["description"]?.stringValue)
        }
        if request.toolName == "WebFetch", let url = detail?["url"]?.stringValue {
            return .fetch(url: url, prompt: detail?["prompt"]?.stringValue)
        }
        if request.toolName == "ApplyPatch", let patch = detail?["patch_text"]?.stringValue { return .text(patch) }
        if request.toolName.hasPrefix("mcp__") { return nil }
        return detailText.map(PermissionPreview.text)
    }
}

extension ToolCall {
    /// Diff de l'appel : celui de l'hôte s'il en a produit un (Edit / Write qui modifie : numéros réels), sinon calculé
    /// d'après les arguments (Edit en attente ou en cours, Write qui crée un fichier : l'hôte n'en produit jamais).
    public var fileDiff: FileDiff? {
        if let display = output?.fileDiff {
            return UnifiedDiff.file(path: display.filePath, hunks: display.hunks, truncated: display.truncated,
                                    additions: display.additions, deletions: display.deletions)
        }
        return ToolDiffs.fromArguments(toolName: toolName, input)
    }
}

enum ToolDiffs {
    /// Edit : `old_string` → `new_string` ; Write : tout `content` en ajout ; autre outil : `nil`.
    static func fromArguments(toolName: String, _ arguments: JSONValue?) -> FileDiff? {
        guard let arguments else { return nil }
        let path = arguments["file_path"]?.stringValue
        switch toolName {
        case "Edit":
            guard let old = arguments["old_string"]?.stringValue, let new = arguments["new_string"]?.stringValue else { return nil }
            return LineDiff.between(old, new, path: path)
        case "Write":
            guard let content = arguments["content"]?.stringValue else { return nil }
            return LineDiff.between("", content, path: path)
        default:
            return nil
        }
    }
}
