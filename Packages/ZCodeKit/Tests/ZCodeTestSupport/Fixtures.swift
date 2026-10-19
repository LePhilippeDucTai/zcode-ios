import Foundation
import ZCodeWire

/// Un enregistrement de `zcode-probe --record` (`{"kind","name","seq","step","value"}`).
public struct FixtureRecord: Sendable {
    public let file: String
    public let kind: String
    public let name: String
    public let value: JSONValue
}

/// Lecture des fixtures de `Tests/Fixtures`.
public enum Fixtures {
    public static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures")

    /// Fichier JSON brut, ex. `synthetic/fragments-v3.json`.
    public static func file(_ path: String) throws -> JSONValue {
        try JSONValue.decode(Data(contentsOf: directory.appending(path: path)))
    }

    /// Valeur (`value`) d'un enregistrement, ex. `v3.15.1/send-text/004-event-….json`.
    public static func recorded(_ path: String) throws -> JSONValue {
        try file(path)["value"] ?? .null
    }

    /// Enregistrements d'un dossier, dans l'ordre de capture (préfixe numérique du nom de fichier).
    public static func records(in folder: String) throws -> [FixtureRecord] {
        let folderURL = directory.appending(path: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { name in
            let record = try JSONValue.decode(Data(contentsOf: folderURL.appending(path: name)))
            return FixtureRecord(
                file: name,
                kind: record["kind"]?.stringValue ?? "",
                name: record["name"]?.stringValue ?? "",
                value: record["value"] ?? .null
            )
        }
    }

    /// `value` de l'enregistrement du dossier dont le nom de fichier commence par `prefix` (ex. `"005"`), dans l'ordre
    /// de capture. Lève si aucun fichier ne porte ce préfixe : un test ne doit pas passer sur une valeur absente.
    public static func record(in folder: String, prefix: String) throws -> JSONValue {
        guard let found = try records(in: folder).first(where: { $0.file.hasPrefix(prefix) }) else {
            throw FixtureError.noRecord(folder: folder, prefix: prefix)
        }
        return found.value
    }
}

public enum FixtureError: Error, Equatable {
    case noRecord(folder: String, prefix: String)
}
