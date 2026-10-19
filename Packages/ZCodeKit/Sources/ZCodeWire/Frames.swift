import Foundation

/// En-tête de trame (`packages/rpc/src/protocol.ts`) :
/// `type: u8 | id: u32 BE | ack: u32 BE | longueur: u32 BE`, suivi de la charge utile.
public enum FrameCodec {
    public static let headerSize = 13

    /// Encadre un message RPC dans une trame `regular` (id = 0, ack = 0), comme `SocketProtocol.send`.
    public static func encodeRegular(_ payload: Data) -> Data {
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(ProtocolMessageType.regular.rawValue)
        appendUInt32BE(0, to: &frame)
        appendUInt32BE(0, to: &frame)
        appendUInt32BE(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return frame
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

public enum FrameDecodingError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
}

/// Réassemble les trames depuis des morceaux d'octets arbitraires (équivalent de `ChunkStream` et
/// `SocketProtocol.readMessages`). Seules les charges utiles des trames `regular` sont restituées.
public struct FrameDecoder: Sendable {
    public let maximumPayloadSize: Int
    private var buffer: [UInt8] = []
    private var start = 0

    public init(maximumPayloadSize: Int = 64 << 20) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    public mutating func append(_ chunk: Data) throws(FrameDecodingError) -> [Data] {
        buffer.append(contentsOf: chunk)
        var payloads: [Data] = []
        while buffer.count - start >= FrameCodec.headerSize {
            let length = Int(readUInt32BE(at: start + 9))
            guard length <= maximumPayloadSize else { throw .frameTooLarge(length) }
            let frameLength = FrameCodec.headerSize + length
            guard buffer.count - start >= frameLength else { break }
            if buffer[start] == ProtocolMessageType.regular.rawValue {
                payloads.append(Data(buffer[(start + FrameCodec.headerSize)..<(start + frameLength)]))
            }
            start += frameLength
        }
        compact()
        return payloads
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 65_536 {
            buffer.removeFirst(start)
            start = 0
        }
    }

    private func readUInt32BE(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16
            | UInt32(buffer[index + 2]) << 8 | UInt32(buffer[index + 3])
    }
}
