/// CRC-32 IEEE 802.3 (polynôme réfléchi 0xEDB88320), identique à `crc32WireBytes` de ZCode.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Forme transmise par le serveur : 8 chiffres hexadécimaux en minuscules.
    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let value = String(checksum(bytes), radix: 16)
        return String(repeating: "0", count: 8 - value.count) + value
    }
}
