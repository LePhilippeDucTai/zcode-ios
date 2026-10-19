import Foundation

extension URLSession {
    /// Session de toutes les requêtes vers un hôte ZCode. Leurs URL portent le token (`?token=`, accès shell à
    /// l'hôte) : aucun cache disque (`Cache.db`), cookie ni identifiant conservé.
    public static let zcode: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
