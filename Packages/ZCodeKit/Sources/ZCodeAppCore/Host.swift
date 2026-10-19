import Foundation

/// Un serveur `zcode --web` joignable par le tailnet. Le token n'est **pas** ici : il vit dans le Trousseau.
public struct Host: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// `https://machine.tailnet.ts.net` (sans chemin ni paramètres).
    public var baseURL: URL
    /// Projets ajoutés à la main, en plus de ceux annoncés par `server-info`.
    public var manualWorkspaces: [String]
    /// Mode des sessions créées depuis l'app (`ModeOption.id`) ; `nil` : rien n'est demandé, l'hôte décide.
    /// Optionnel : les hôtes enregistrés avant la Phase 13 se décodent sans migration.
    public var defaultMode: String?

    public init(id: UUID = UUID(), name: String, baseURL: URL, manualWorkspaces: [String] = [], defaultMode: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.manualWorkspaces = manualWorkspaces
        self.defaultMode = defaultMode
    }

    /// Normalise une adresse saisie : `https` obligatoire (le token donne un accès shell à l'hôte), sans chemin,
    /// paramètres (un `?token=` collé depuis Safari est retiré) ni identifiants.
    public static func normalizedURL(_ text: String) throws(HostValidationError) -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidURL }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { throw .invalidURL }
        guard components.scheme?.lowercased() == "https" else { throw .insecureURL }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw .invalidURL }
        return url
    }
}

public enum HostValidationError: Error, Equatable, Sendable {
    case emptyName
    case invalidURL
    case insecureURL
    case emptyToken
    case invalidWorkspace

    public var message: String {
        switch self {
        case .emptyName: "Donne un nom à cet hôte."
        case .invalidURL: "Adresse invalide. Exemple : https://macbook.tailnet.ts.net"
        case .insecureURL: "Seules les adresses https sont acceptées (le token donne un accès complet à l'hôte)."
        case .emptyToken: "Le token est obligatoire."
        case .invalidWorkspace: "Indique le chemin absolu du projet sur l'hôte (il commence par /)."
        }
    }
}
