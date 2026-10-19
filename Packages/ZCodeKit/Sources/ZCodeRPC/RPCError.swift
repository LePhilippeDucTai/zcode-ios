import Foundation
import ZCodeWire

public enum RPCError: Error, Equatable, Sendable {
    /// Erreur levée par le service distant (réponse 202).
    case remote(RemoteError)
    /// Objet d'erreur brut (réponse 203).
    case errorObject(RPCValue)
    /// La connexion s'est terminée normalement ou le client a été fermé.
    case connectionClosed
    /// La connexion a échoué (token refusé, réseau…).
    case transport(TransportError)
    /// Le serveur a envoyé un message illisible ; la connexion est fermée.
    case protocolViolation(String)
}

/// Erreur renvoyée par le serveur (`IRawResponse` 202 de `channels.shared.ts`).
public struct RemoteError: Error, Equatable, Sendable {
    public let message: String
    public let name: String
    public let code: JSONValue?
    public let kind: JSONValue?
    public let data: JSONValue?
    /// Objet d'erreur complet, pour les champs non modélisés.
    public let raw: JSONValue

    public init(_ value: RPCValue) {
        let raw = value.jsonValue ?? .null
        self.raw = raw
        message = raw["message"]?.stringValue ?? "Erreur distante"
        name = raw["name"]?.stringValue ?? "Error"
        code = raw["code"]
        kind = raw["kind"]
        data = raw["data"]
    }
}
