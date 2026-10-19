import Foundation

/// Portée d'une opération sur les extensions (sous-agents, plugins) : le compte de l'utilisateur sur l'hôte, ou un
/// projet de la liste de l'hôte (chemin absolu côté hôte).
public enum ExtensionScope: Hashable, Sendable {
    case user
    case workspace(String)

    /// Valeur du champ `scope` du fil.
    public var wireName: String {
        switch self {
        case .user: "user"
        case .workspace: "workspace"
        }
    }

    /// Projet de la portée ; `nil` pour l'utilisateur (l'appelant fournit alors un projet de l'hôte).
    public var workspacePath: String? {
        switch self {
        case .user: nil
        case .workspace(let path): path
        }
    }
}
