import Foundation
import ZCodeRPC
import ZCodeWire

/// Erreur distante munie d'un `code` (erreurs Node de l'hôte : `ENOENT`, `EACCES`…), à lever depuis un gestionnaire.
public struct FakeRemoteError: Error {
    public let message: String
    public let code: String?

    public init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

/// Faux serveur ZCode pour les tests : répond aux appels selon des gestionnaires par nom (`canal.méthode`) et
/// diffuse des événements aux écoutes ouvertes. Il lit seul `transport.sent` : ne pas le lire ailleurs.
public actor FakeZCodeServer {
    public typealias Handler = @Sendable (_ argument: JSONValue) throws -> JSONValue

    public nonisolated let transport = InMemoryTransport()
    private var handlers: [String: Handler] = [:]
    private var listeners: [Int32: String] = [:]
    /// Méthodes dont la réponse est différée, et requêtes en attente de réponse (identifiants, dans l'ordre d'arrivée).
    private var deferredNames: Set<String> = []
    private var waiting: [String: [Int32]] = [:]
    private var log: [(name: String, argument: JSONValue)] = []
    private var reader: Task<Void, Never>?

    public init() {}

    /// Envoie `Initialize` puis traite les requêtes du client, dans l'ordre.
    public func start() {
        guard reader == nil else { return }
        transport.deliverInitialize()
        let sent = transport.sent
        // Capture forte : le serveur vit tant que son client est connecté (le cycle se rompt à la fin de `sent`),
        // même si le test n'en garde aucune référence (ex. `ServerQueue` qui le cède à la connexion).
        reader = Task {
            for await message in sent {
                handle(message)
            }
        }
    }

    /// Réponse à `canal.méthode` ; un gestionnaire qui lève produit une erreur 202 portant son message.
    public func on(_ name: String, _ handler: @escaping Handler) {
        handlers[name] = handler
    }

    /// `canal.méthode` laisse chaque appel sans réponse jusqu'à `respondDeferred` : la boucle continue de traiter les autres
    /// requêtes, ce qu'un gestionnaire bloqué ne permet pas. L'arrivée de l'appel se voit par `calls(to:)`.
    public func onDeferred(_ name: String) {
        deferredNames.insert(name)
    }

    /// Répond à la plus ancienne requête en attente de `canal.méthode` ; sans effet s'il n'y en a pas.
    public func respondDeferred(_ name: String, _ value: JSONValue) {
        guard var ids = waiting[name], !ids.isEmpty else { return }
        let id = ids.removeFirst()
        waiting[name] = ids
        transport.respond(to: id, with: value)
    }

    /// Diffuse `value` à chaque écoute ouverte sur `canal.événement`.
    public func emit(_ name: String, _ value: JSONValue) {
        for (id, event) in listeners where event == name {
            transport.emit(listener: id, value)
        }
    }

    public func listenerCount(_ name: String) -> Int {
        listeners.values.filter { $0 == name }.count
    }

    /// Arguments reçus par `canal.méthode`, dans l'ordre.
    public func calls(to name: String) -> [JSONValue] {
        log.filter { $0.name == name }.map(\.argument)
    }

    /// `canal.méthode` de tous les appels reçus, dans l'ordre (pour vérifier un enchaînement entre méthodes).
    public func callNames(prefix: String = "") -> [String] {
        log.map(\.name).filter { $0.hasPrefix(prefix) }
    }

    private func handle(_ message: Data) {
        guard let decoded = try? decodeSent(message),
              case .array(let fields) = decoded.header,
              fields.count >= 2, case .int(let type) = fields[0], case .int(let id) = fields[1]
        else { return }
        switch RequestType(rawValue: type) {
        case .promise:
            guard fields.count >= 4, case .string(let channel) = fields[2], case .string(let method) = fields[3] else { return }
            let name = "\(channel).\(method)"
            let argument = decoded.body.jsonValue?.arrayValue?.first ?? .null
            log.append((name, argument))
            if deferredNames.contains(name) {
                waiting[name, default: []].append(id)
                return
            }
            guard let handler = handlers[name] else {
                fail(id, "méthode non simulée : \(name)")
                return
            }
            do {
                transport.respond(to: id, with: try handler(argument))
            } catch let remote as FakeRemoteError {
                fail(id, remote.message, code: remote.code)
            } catch {
                fail(id, String(describing: error))
            }
        case .eventListen:
            guard fields.count >= 4, case .string(let channel) = fields[2], case .string(let event) = fields[3] else { return }
            listeners[id] = "\(channel).\(event)"
        case .eventDispose:
            listeners[id] = nil
        case .promiseCancel, nil:
            break
        }
    }

    private func fail(_ id: Int32, _ message: String, code: String? = nil) {
        var error: [String: JSONValue] = ["message": .string(message), "name": .string("Error")]
        if let code { error["code"] = .string(code) }
        transport.deliver(.array([.int(ResponseType.promiseError.rawValue), .int(id)]), .json(.object(error)))
    }
}
