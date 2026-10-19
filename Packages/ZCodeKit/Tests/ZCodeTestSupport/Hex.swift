import Foundation

extension Data {
    /// Construit des octets depuis une chaîne hexadécimale (les espaces sont ignorés).
    public init(hex: String) {
        let digits = Array(hex.filter { !$0.isWhitespace })
        precondition(digits.count.isMultiple(of: 2), "chaîne hexadécimale de longueur impaire")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            bytes.append(UInt8(String(digits[index...index + 1]), radix: 16)!)
        }
        self.init(bytes)
    }

    /// Représentation hexadécimale en minuscules, sans séparateur.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
