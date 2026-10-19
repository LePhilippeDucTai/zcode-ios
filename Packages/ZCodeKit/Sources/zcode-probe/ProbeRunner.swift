import Foundation
import ZCodeRPC
import ZCodeWire

/// Écrit une ligne JSON par enregistrement et, si demandé, un fichier par enregistrement.
actor ProbeOutput {
    private let recordDirectory: URL?
    private var sequence = 0

    init(recordDirectory: URL?) throws {
        self.recordDirectory = recordDirectory
        if let recordDirectory {
            try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: true)
        }
    }

    func emit(kind: String, step: Int, name: String, value: JSONValue?) {
        sequence += 1
        let record = JSONValue.object([
            "seq": .number(Double(sequence)),
            "kind": .string(kind),
            "step": .number(Double(step)),
            "name": .string(name),
            "value": value?.redactingSecrets() ?? .null,
        ])
        if let line = try? record.jsonData() {
            print(String(decoding: line, as: UTF8.self))
        }
        if let recordDirectory {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let file = recordDirectory.appending(path: String(format: "%03d", sequence) + "-\(kind)-\(name).json")
            try? encoder.encode(record).write(to: file)
        }
    }
}

struct ProbeRunner {
    let client: ChannelClient
    let output: ProbeOutput

    func run(_ script: ProbeScript) async throws {
        var listenerTasks: [Task<Void, Never>] = []
        for (index, step) in script.steps.enumerated() {
            switch step {
            case .call(let channel, let method, let args):
                let name = "\(channel).\(method)"
                do {
                    let result = try await client.call(channel, method, .array(args.map(RPCValue.init)))
                    await output.emit(kind: "result", step: index, name: name, value: result.jsonValue)
                } catch {
                    await output.emit(kind: "error", step: index, name: name, value: Self.describe(error))
                }
            case .listen(let channel, let event, let arg):
                let name = "\(channel).\(event)"
                let stream = try await client.listen(channel, event, arg.map(RPCValue.init) ?? .undefined)
                listenerTasks.append(Task {
                    for await value in stream {
                        await output.emit(kind: "event", step: index, name: name, value: value.jsonValue)
                    }
                })
            case .wait(let seconds):
                try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            }
        }
        for task in listenerTasks {
            task.cancel()
        }
    }

    private static func describe(_ error: any Error) -> JSONValue {
        if case RPCError.remote(let remote) = error {
            return remote.raw
        }
        return .string(String(describing: error))
    }
}

extension JSONValue {
    /// Une clé est sensible si son nom (normalisé, sans `_` ni `-`) se termine par `token` ou contient l'un de ces
    /// mots ; les compteurs (`usedTokens`, `maxTokens`) restent visibles.
    private static let secretFragments = ["apikey", "secret", "password", "authorization", "credential", "cookie"]

    private static func isSecretKey(_ key: String) -> Bool {
        let name = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return name.hasSuffix("token") || secretFragments.contains { name.contains($0) }
    }

    /// Copie où les valeurs des clés sensibles sont masquées : la vue `provider-settings`, par exemple,
    /// renvoie les clés d'API en clair. Rien de secret ne doit atteindre la sortie ni les fixtures.
    func redactingSecrets() -> JSONValue {
        switch self {
        case .object(let object):
            var redacted: [String: JSONValue] = [:]
            for (key, value) in object {
                redacted[key] = Self.isSecretKey(key) && value != .null
                    ? .string("••••")
                    : value.redactingSecrets()
            }
            return .object(redacted)
        case .array(let items):
            return .array(items.map { $0.redactingSecrets() })
        default:
            return self
        }
    }
}
