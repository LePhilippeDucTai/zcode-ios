import Foundation

public enum RPCDecodingError: Error, Equatable, Sendable {
    case truncated
    case unknownTag(UInt8)
    case malformedVQL
    case invalidJSON
}

/// Sérialisation binaire des messages RPC (format VS Code : étiquette + longueur VQL + données).
public enum RPCSerializer {
    /// Sérialise les valeurs les unes à la suite des autres. Un message RPC = en-tête + corps.
    public static func encode(_ values: RPCValue...) -> Data {
        var data = Data()
        for value in values {
            append(value, to: &data)
        }
        return data
    }

    public static func append(_ value: RPCValue, to data: inout Data) {
        switch value {
        case .undefined:
            data.append(0)
        case .string(let string):
            appendBytes(tag: 1, Data(string.utf8), to: &data)
        case .buffer(let bytes):
            appendBytes(tag: 2, bytes, to: &data)
        case .vsBuffer(let bytes):
            appendBytes(tag: 3, bytes, to: &data)
        case .array(let items):
            data.append(4)
            appendVQL(UInt32(items.count), to: &data)
            for item in items {
                append(item, to: &data)
            }
        case .json(let json):
            // Seuls NaN et ±∞ (impossibles depuis du JSON décodé) font échouer l'encodage.
            appendBytes(tag: 5, (try? json.jsonData()) ?? Data("null".utf8), to: &data)
        case .int(let integer):
            data.append(6)
            appendVQL(UInt32(bitPattern: integer), to: &data)
        }
    }

    private static func appendBytes(tag: UInt8, _ bytes: Data, to data: inout Data) {
        data.append(tag)
        appendVQL(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    /// VQL : 7 bits par octet, poids faibles d'abord, bit de poids fort = « octet suivant ».
    static func appendVQL(_ value: UInt32, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
    }
}

/// Lecture séquentielle de valeurs sérialisées.
public struct RPCReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ data: Data) {
        bytes = Array(data)
    }

    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func decode() throws(RPCDecodingError) -> RPCValue {
        let tag = try readByte()
        switch tag {
        case 0:
            return .undefined
        case 1:
            // Décodage UTF-8 permissif, comme `toString()` côté JavaScript.
            return .string(String(decoding: try readBytes(try readLength()), as: UTF8.self))
        case 2:
            return .buffer(Data(try readBytes(try readLength())))
        case 3:
            return .vsBuffer(Data(try readBytes(try readLength())))
        case 4:
            let count = try readLength()
            var items: [RPCValue] = []
            items.reserveCapacity(min(count, 1024))
            for _ in 0..<count {
                items.append(try decode())
            }
            return .array(items)
        case 5:
            let json = Data(try readBytes(try readLength()))
            guard let value = try? JSONValue.decode(json) else { throw .invalidJSON }
            return .json(value)
        case 6:
            return .int(Int32(bitPattern: try readVQL()))
        default:
            throw .unknownTag(tag)
        }
    }

    private mutating func readByte() throws(RPCDecodingError) -> UInt8 {
        guard offset < bytes.count else { throw .truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readBytes(_ count: Int) throws(RPCDecodingError) -> ArraySlice<UInt8> {
        guard count <= bytes.count - offset else { throw .truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    private mutating func readLength() throws(RPCDecodingError) -> Int {
        Int(try readVQL())
    }

    private mutating func readVQL() throws(RPCDecodingError) -> UInt32 {
        var value: UInt32 = 0
        var shift: UInt32 = 0
        for _ in 0..<5 {
            let byte = try readByte()
            value |= UInt32(byte & 0x7F) &<< shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        throw .malformedVQL
    }
}
