import Foundation

public enum WorkspacePaths {
    /// Chemin relatif au projet pour l'affichage (`/Users/x/projet/a/b.swift` → `a/b.swift`) ; un chemin hors du
    /// projet reste absolu.
    public static func display(_ path: String, in workspace: String) -> String {
        let root = workspace.hasSuffix("/") ? workspace : workspace + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
