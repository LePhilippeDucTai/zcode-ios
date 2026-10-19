import Foundation
import ZCodeWire

/// Types de requêtes (`RequestType` de `channels.shared.ts`).
public enum RequestType: Int32, Sendable {
    case promise = 100
    case promiseCancel = 101
    case eventListen = 102
    case eventDispose = 103
}

/// Types de réponses (`ResponseType` de `channels.shared.ts`).
public enum ResponseType: Int32, Sendable {
    case initialize = 200
    case promiseSuccess = 201
    case promiseError = 202
    case promiseErrorObject = 203
    case eventFire = 204
}

public enum RPCResponse: Equatable, Sendable {
    case initialize
    case success(id: Int32, data: RPCValue)
    case error(id: Int32, data: RPCValue)
    case errorObject(id: Int32, data: RPCValue)
    case event(id: Int32, data: RPCValue)
    case unknown(type: Int32)
}

/// Encodage des requêtes et lecture des réponses : chaque message = en-tête sérialisé + corps sérialisé.
public enum RPCMessage {
    /// `[type, id, canal, nom]` + argument (appel de méthode ou écoute d'événement).
    public static func request(_ type: RequestType, id: Int32, channel: String, name: String, arg: RPCValue) -> Data {
        RPCSerializer.encode(.array([.int(type.rawValue), .int(id), .string(channel), .string(name)]), arg)
    }

    /// `[type, id]` + `undefined` (annulation d'appel ou fin d'écoute).
    public static func dispose(_ type: RequestType, id: Int32) -> Data {
        RPCSerializer.encode(.array([.int(type.rawValue), .int(id)]), .undefined)
    }

    public static func parseResponse(_ message: Data) throws -> RPCResponse {
        var reader = RPCReader(message)
        let header = try reader.decode()
        let body = reader.isAtEnd ? RPCValue.undefined : try reader.decode()
        guard case .array(let fields) = header, case .int(let rawType)? = fields.first else {
            throw RPCError.protocolViolation("en-tête de réponse invalide")
        }
        guard let type = ResponseType(rawValue: rawType) else {
            return .unknown(type: rawType)
        }
        if type == .initialize {
            return .initialize
        }
        guard fields.count >= 2, case .int(let id) = fields[1] else {
            throw RPCError.protocolViolation("identifiant de réponse manquant")
        }
        switch type {
        case .initialize: return .initialize
        case .promiseSuccess: return .success(id: id, data: body)
        case .promiseError: return .error(id: id, data: body)
        case .promiseErrorObject: return .errorObject(id: id, data: body)
        case .eventFire: return .event(id: id, data: body)
        }
    }
}
