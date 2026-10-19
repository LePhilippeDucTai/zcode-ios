/// Type d'une trame du protocole socket ZCode (`packages/rpc/src/protocol.ts`).
///
/// Sur `/ws`, seules les trames `regular` transportent des messages RPC ;
/// les autres types appartiennent au protocole persistant et sont ignorés.
public enum ProtocolMessageType: UInt8, Sendable {
    case none = 0
    case regular = 1
    case control = 2
    case ack = 3
    case disconnect = 5
    case replayRequest = 6
    case pause = 7
    case resume = 8
    case keepAlive = 9
}
