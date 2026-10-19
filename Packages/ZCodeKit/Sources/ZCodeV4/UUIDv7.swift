import Foundation

/// UUID version 7 (`uuid.ts`) : 48 bits de millisecondes en tête, puis de l'aléa.
public enum UUIDv7 {
    public static func make(at date: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(at: date, using: &generator)
    }

    public static func make<G: RandomNumberGenerator>(at date: Date, using generator: inout G) -> String {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * UInt64(5 - index)))
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        let hex = bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        let characters = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }.joined(separator: "-")
    }

    /// Instant encodé dans un UUIDv7 ; `nil` si la chaîne n'en est pas un.
    public static func timestamp(of uuid: String) -> Date? {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, uuid.count == 36, Array(hex)[12] == "7",
              let milliseconds = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
