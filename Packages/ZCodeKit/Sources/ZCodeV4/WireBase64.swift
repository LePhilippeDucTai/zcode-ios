import Foundation

/// Base64 strict des fragments, comme `topicWireBase64Schema` : au moins 4 caractères, longueur
/// multiple de 4, alphabet standard, remplissage `=` uniquement en fin (au plus 2).
public enum WireBase64 {
    public static func decode(_ string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 4, bytes.count.isMultiple(of: 4) else { return nil }
        let equals = UInt8(ascii: "=")
        let padding = bytes.reversed().prefix { $0 == equals }.count
        guard padding <= 2 else { return nil }
        for byte in bytes.dropLast(padding) where !isAlphabet(byte) {
            return nil
        }
        return Data(base64Encoded: string)
    }

    private static func isAlphabet(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
            true
        default:
            false
        }
    }
}
