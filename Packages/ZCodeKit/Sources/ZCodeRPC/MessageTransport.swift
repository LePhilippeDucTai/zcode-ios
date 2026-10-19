import Foundation

/// Transport de messages RPC déjà désencadrés (équivalent de `IMessagePassingProtocol`).
public protocol MessageTransport: Sendable {
    /// Envoie un message. L'ordre d'envoi est préservé ; un échec d'envoi termine `messages` en erreur.
    func send(_ message: Data)
    /// Messages reçus du serveur ; le flux se termine à la fermeture de la connexion.
    var messages: AsyncThrowingStream<Data, any Error> { get }
    /// Ferme la connexion.
    func close()
}

public enum TransportError: Error, Equatable, Sendable {
    /// Le serveur a refusé le token (HTTP 401 à l'ouverture du WebSocket).
    case unauthorized
    /// Le serveur a envoyé un message texte au lieu d'octets.
    case unexpectedTextMessage
    case connectionFailed(String)
}
