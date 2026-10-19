import Foundation
import ZCodeWire

/// Entrée d'un dossier (`FileEntry` de `file.readdir`). Un lien symbolique vers un dossier est un dossier.
public struct FileEntry: Hashable, Sendable, Identifiable {
    public let name: String
    /// Chemin absolu sur l'hôte.
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public var id: String { path }

    /// Liste dans l'ordre de l'hôte (dossiers d'abord) ; une entrée sans nom ou sans chemin est ignorée.
    public static func list(json: JSONValue) throws(V4DecodingError) -> [FileEntry] {
        guard let items = json.arrayValue else { throw .invalid("file.readdir") }
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue, !name.isEmpty,
                  let path = item["path"]?.stringValue, !path.isEmpty else { return nil }
            return FileEntry(name: name, path: path, isDirectory: item["type"]?.stringValue == "directory",
                             isSymbolicLink: item["isSymbolicLink"]?.boolValue ?? false)
        }
    }
}

/// Tronçon lu par `file.readTextFile` (256 Kio au plus). Un fichier trop gros (`truncated`) ou binaire (`isBinary`,
/// contenu vide) n'est pas une erreur. Le tronçon peut finir par un caractère multi-octets coupé (U+FFFD).
public struct FileTextSlice: Equatable, Sendable {
    public let path: String
    public let content: String
    public let totalBytes: Int
    public let bytesRead: Int
    public let truncated: Bool
    public let isBinary: Bool

    public init(json: JSONValue) throws(V4DecodingError) {
        guard let content = json["content"]?.stringValue else { throw .invalid("file.readTextFile") }
        self.content = content
        path = json["path"]?.stringValue ?? ""
        totalBytes = V4JSON.integer(json["totalBytes"]) ?? content.utf8.count
        bytesRead = V4JSON.integer(json["bytesRead"]) ?? content.utf8.count
        truncated = json["truncated"]?.boolValue ?? false
        isBinary = json["isBinary"]?.boolValue ?? false
    }
}

/// Résultat de `file.searchWorkspaceFiles` : recherche floue de l'hôte, dossiers et fichiers cachés compris.
public struct WorkspaceFileMatch: Hashable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let relativePath: String
    public let isDirectory: Bool

    public var id: String { path }

    public static func list(json: JSONValue) throws(V4DecodingError) -> [WorkspaceFileMatch] {
        guard let items = json.arrayValue else { throw .invalid("file.searchWorkspaceFiles") }
        return items.compactMap { item in
            guard let path = item["path"]?.stringValue, !path.isEmpty else { return nil }
            let name = item["name"]?.stringValue ?? URL(filePath: path).lastPathComponent
            return WorkspaceFileMatch(name: name, path: path, relativePath: item["relativePath"]?.stringValue ?? path,
                                      isDirectory: item["type"]?.stringValue == "directory")
        }
    }
}
