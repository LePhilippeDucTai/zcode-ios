import CryptoKit
import Foundation
import ZCodeRPC
import ZCodeV4
import ZCodeWire

public enum AgentV4Error: Error, Equatable, Sendable {
    /// Le serveur parle une autre version de trame : seule la vue web reste utilisable.
    case unsupportedProtocol(Int)
    /// Réponse de forme inattendue (ZCode a changé ?).
    case malformedResponse(method: String, detail: String)
}

/// Canal `zcode-agent` d'un espace de travail, en appels typés.
public struct AgentV4: Sendable {
    public let client: ChannelClient
    public let workspacePath: String

    public init(client: ChannelClient, workspacePath: String) {
        self.client = client
        self.workspacePath = workspacePath
    }

    // MARK: - Connexion

    /// `helloConversationV4` → contrôle de `protocolVersion` → `initializeConversationV4`.
    @discardableResult
    public func handshake(clientId: String, appVersion: String) async throws -> HelloMessage {
        let hello = try decode(HelloMessage.self, await call("helloConversationV4", nil), method: "helloConversationV4")
        guard hello.protocolVersion == V4Protocol.wireVersion else {
            throw AgentV4Error.unsupportedProtocol(hello.protocolVersion)
        }
        _ = try await call("initializeConversationV4", ClientHello(clientId: clientId, appVersion: appVersion).json)
        return hello
    }

    /// Trames de toutes les conversations de l'espace de travail (à filtrer par sujet).
    public func conversationFrames() async throws -> AsyncStream<JSONValue> {
        try await frames("onDynamicConversationFrame")
    }

    public func sessionsIndexFrames() async throws -> AsyncStream<JSONValue> {
        try await frames("onDynamicSessionsIndexFrame")
    }

    // MARK: - Conversation

    public func subscribeConversation(sessionId: String, base: Watermark? = nil) async throws -> SubscribeAck {
        var params: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let base { params["base"] = base.json }
        return try await ack("subscribeConversationV4", params)
    }

    public func resyncConversation(subscriptionId: String, base: Watermark?, forceSnapshot: Bool) async throws -> SubscribeAck {
        try await ack("resyncConversationV4", resyncParams(subscriptionId, base, forceSnapshot))
    }

    public func unsubscribeConversation(subscriptionId: String) async throws {
        _ = try await call("unsubscribeConversationV4", workspaceParams(["subscriptionId": .string(subscriptionId)]))
    }

    /// Page d'historique : lignes `rowId < beforeRowId` (ou fin de conversation si `nil`).
    public func rowsRange(sessionId: String, beforeRowId: Int? = nil, limit: Int = V4Protocol.rowsRangeMaxLimit) async throws -> RowsRangePage {
        var params: [String: JSONValue] = ["sessionId": .string(sessionId), "limit": .number(Double(limit))]
        if let beforeRowId { params["beforeRowId"] = .number(Double(beforeRowId)) }
        let method = "conversationRowsRangeV4"
        let value = try await call(method, workspaceParams(params))
        do {
            return try RowsRangePage(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: method, detail: "\(error)")
        }
    }

    /// Fichiers modifiés par le tour de `target` (en-tête de tour), à la révision `base`.
    public func fileChanges(sessionId: String, target: RowTarget, base: CommandBase) async throws -> FileChanges {
        let method = "conversationFileChangesV4"
        let value = try await call(method, workspaceParams([
            "sessionId": .string(sessionId),
            "target": target.json,
            "baseRevision": .number(Double(base.revision)),
            "baseLogEpoch": .string(base.logEpoch),
        ]))
        return try decode(FileChanges.self, value, method: method)
    }

    public func send(_ envelope: CommandEnvelope) async throws -> CommandAck {
        let method = "sendConversationCommandV4"
        let value = try await call(method, workspaceParams(["envelope": envelope.json]))
        do {
            return try CommandAck(json: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: method, detail: "\(error)")
        }
    }

    /// Sort de commandes envoyées avant une coupure (renvoyer celles qui sont `.unknown`).
    public func queryCommands(_ keys: [CommandKey]) async throws -> [CommandQueryItem] {
        let method = "queryConversationCommandsV4"
        let value = try await call(method, workspaceParams(["commands": .array(keys.map(\.json))]))
        do {
            return try CommandsQuery.parse(value)
        } catch {
            throw AgentV4Error.malformedResponse(method: method, detail: "\(error)")
        }
    }

    // MARK: - Pièces jointes

    /// Morceau téléversé (comme le web) : multiple de 3, donc base64 sans remplissage sauf le dernier ; 512 Kio au plus.
    public static let attachmentChunkBytes = 384 * 1024
    /// Page lue par `attachmentReadV4` (plafond de l'hôte).
    public static let attachmentReadLimit = 512 * 1024

    /// Téléverse `data` dans la session (`attachmentBeginV4`, `attachmentChunkV4`…, `attachmentCommitV4`) et rend la
    /// référence à joindre à `sendText`. Reprend où l'hôte en est (`nextChunkIndex`) ; sur erreur, l'envoi est abandonné
    /// (`attachmentAbortV4`, envoyé même si l'appelant annule ; son échec est ignoré : l'hôte purge de toute façon au
    /// bout de 5 min).
    public func uploadAttachment(sessionId: String, fileName: String, mime: String, data: Data,
                                 uploadId: String = "upload-" + UUID().uuidString.lowercased()) async throws -> AttachmentRef {
        let size = Self.attachmentChunkBytes
        let totalChunks = (data.count + size - 1) / size
        let common: [String: JSONValue] = ["sessionId": .string(sessionId), "uploadId": .string(uploadId)]
        let reference = { (ref: String) in AttachmentRef(ref: ref, fileName: fileName, mime: mime, bytes: data.count) }
        let begin = try await call("attachmentBeginV4", workspaceParams(common.merging([
            "fileName": .string(fileName), "mime": .string(mime), "totalBytes": .number(Double(data.count)),
            "totalChunks": .number(Double(totalChunks)), "checksum": .string(Self.checksum(data)),
        ]) { current, _ in current }))
        if begin["state"]?.stringValue == "committed", let ref = begin["ref"]?.stringValue, !ref.isEmpty {
            return reference(ref)
        }
        do {
            guard let start = V4JSON.integer(begin["nextChunkIndex"]), (0...totalChunks).contains(start) else {
                throw AgentV4Error.malformedResponse(method: "attachmentBeginV4", detail: "nextChunkIndex incohérent")
            }
            for index in start..<totalChunks {
                let lower = index * size
                let chunk = data.subdata(in: lower..<min(lower + size, data.count))
                let progress = try await call("attachmentChunkV4", workspaceParams(common.merging([
                    "chunkIndex": .number(Double(index)), "dataBase64": .string(chunk.base64EncodedString()),
                ]) { current, _ in current }))
                guard V4JSON.integer(progress["nextChunkIndex"]) == index + 1 else {
                    throw AgentV4Error.malformedResponse(method: "attachmentChunkV4", detail: "nextChunkIndex incohérent")
                }
            }
            let commit = try await call("attachmentCommitV4", workspaceParams(common))
            guard let ref = commit["ref"]?.stringValue, !ref.isEmpty else {
                throw AgentV4Error.malformedResponse(method: "attachmentCommitV4", detail: "ref absente")
            }
            return reference(ref)
        } catch {
            // Tâche non structurée : elle n'hérite pas de l'annulation (sinon `call` échouerait aussitôt et l'abandon
            // ne partirait jamais quand c'est l'appelant qui annule l'envoi).
            let abort = workspaceParams(common)
            _ = await Task { try? await call("attachmentAbortV4", abort) }.value
            throw error
        }
    }

    /// Contenu d'une pièce jointe d'un message (`attachmentReadV4`, images / vidéos / PDF), page après page jusqu'à
    /// `nextOffset == null` ; au-delà de `maxBytes`, la lecture est abandonnée.
    public func readAttachment(sessionId: String, ref: String, maxBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            let page = try await call("attachmentReadV4", workspaceParams([
                "sessionId": .string(sessionId), "ref": .string(ref), "offset": .number(Double(offset)),
                "limit": .number(Double(Self.attachmentReadLimit)),
            ]))
            guard let base64 = page["dataBase64"]?.stringValue, let chunk = Data(base64Encoded: base64) else {
                throw AgentV4Error.malformedResponse(method: "attachmentReadV4", detail: "dataBase64")
            }
            data.append(chunk)
            guard data.count <= maxBytes else {
                throw AgentV4Error.malformedResponse(method: "attachmentReadV4", detail: "plus de \(maxBytes) octets")
            }
            guard let next = V4JSON.integer(page["nextOffset"]) else { return data }      // `null` : fin
            guard next > offset else {
                throw AgentV4Error.malformedResponse(method: "attachmentReadV4", detail: "nextOffset incohérent")
            }
            offset = next
        }
    }

    private static func checksum(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Index des sessions

    public func subscribeSessionsIndex(base: Watermark? = nil) async throws -> SubscribeAck {
        var params: [String: JSONValue] = [:]
        if let base { params["base"] = base.json }
        return try await ack("subscribeSessionsIndexV4", params)
    }

    public func resyncSessionsIndex(subscriptionId: String, base: Watermark?, forceSnapshot: Bool) async throws -> SubscribeAck {
        try await ack("resyncSessionsIndexV4", resyncParams(subscriptionId, base, forceSnapshot))
    }

    public func unsubscribeSessionsIndex(subscriptionId: String) async throws {
        _ = try await call("unsubscribeSessionsIndexV4", workspaceParams(["subscriptionId": .string(subscriptionId)]))
    }

    // MARK: - Interne

    private func workspaceParams(_ params: [String: JSONValue]) -> JSONValue {
        .object(params.merging(["workspacePath": .string(workspacePath)]) { _, workspace in workspace })
    }

    private func resyncParams(_ subscriptionId: String, _ base: Watermark?, _ forceSnapshot: Bool) -> [String: JSONValue] {
        ["subscriptionId": .string(subscriptionId), "base": base?.json ?? .null, "forceSnapshot": .bool(forceSnapshot)]
    }

    private func ack(_ method: String, _ params: [String: JSONValue]) async throws -> SubscribeAck {
        let value = try await call(method, workspaceParams(params))
        do {
            return try SubscribeAck(result: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: method, detail: "\(error)")
        }
    }

    /// Appel de méthode : arguments en tableau (`[]` sans paramètre).
    private func call(_ method: String, _ argument: JSONValue?) async throws -> JSONValue {
        let arguments: [RPCValue] = argument.map { [RPCValue($0)] } ?? []
        return try await client.call(V4Protocol.agentChannel, method, .array(arguments)).jsonValue ?? .null
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue, method: String) throws -> T {
        do {
            return try V4JSON.decode(type, from: value)
        } catch {
            throw AgentV4Error.malformedResponse(method: method, detail: "\(error)")
        }
    }

    /// Écoute d'un événement `onDynamicXxx({workspacePath})` ; terminer le flux arrête l'écoute.
    private func frames(_ event: String) async throws -> AsyncStream<JSONValue> {
        let raw = try await client.listen(V4Protocol.agentChannel, event, RPCValue(.object(["workspacePath": .string(workspacePath)])))
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let relay = Task {
            for await value in raw {
                if let json = value.jsonValue { continuation.yield(json) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return stream
    }
}
