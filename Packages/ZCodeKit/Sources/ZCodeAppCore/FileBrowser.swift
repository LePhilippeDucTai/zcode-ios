import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Contenu d'un fichier prêt à afficher.
public enum FileContent: Equatable, Sendable {
    /// `truncated` : seuls les 256 premiers Kio ont été lus (plafond de l'hôte).
    case text(lines: [String], truncated: Bool, totalBytes: Int)
    case binary(totalBytes: Int)
    case failed(String)
}

/// Navigateur de fichiers d'un projet (canal `file`, lecture seule). L'hôte ne borne rien au projet : l'app ne
/// part que de `root` et des chemins que l'hôte renvoie.
@MainActor
@Observable
public final class FileBrowser {
    public enum Listing: Equatable, Sendable {
        case loading
        case loaded([FileEntry])
        case failed(String)
    }

    public let root: String
    /// Fichiers cachés (nom en `.`) : masqués par défaut, comme dans ZCode.
    public private(set) var showsHidden = false
    public private(set) var searchQuery = ""
    public private(set) var searchResults: [WorkspaceFileMatch] = []
    public private(set) var searchFailure: String?
    private var listings: [String: Listing] = [:]
    private let connection: HostConnection
    @ObservationIgnored private var searchGeneration = 0

    public init(connection: HostConnection, root: String) {
        self.connection = connection
        self.root = root
    }

    public func listing(_ path: String) -> Listing? {
        listings[path]
    }

    /// Lit un dossier ; une liste déjà affichée le reste pendant la lecture.
    public func load(_ path: String) async {
        if listings[path] == nil { listings[path] = .loading }
        let hidden = showsHidden
        guard let channel = await connection.ensureConnected() else {
            listings[path] = .failed(connection.failure?.message ?? "Hôte injoignable.")
            return
        }
        do {
            let entries = try await FileClient(client: channel).readdir(path: path, includeHidden: hidden)
            guard hidden == showsHidden else { return }          // bascule pendant la lecture : la relecture gagne
            listings[path] = .loaded(entries)
        } catch {
            guard hidden == showsHidden else { return }
            listings[path] = .failed(WorkspaceErrors.message(error))
        }
    }

    /// Montre ou masque les fichiers cachés, puis relit les dossiers déjà ouverts.
    public func setShowsHidden(_ value: Bool) async {
        guard value != showsHidden else { return }
        showsHidden = value
        for path in listings.keys.sorted() {
            await load(path)
        }
    }

    /// Les 256 premiers Kio d'un fichier, découpés en lignes.
    public func read(_ path: String) async -> FileContent {
        guard let channel = await connection.ensureConnected() else {
            return .failed(connection.failure?.message ?? "Hôte injoignable.")
        }
        do {
            return Self.content(try await FileClient(client: channel).readTextFile(path: path))
        } catch {
            return .failed(WorkspaceErrors.message(error))
        }
    }

    static func content(_ slice: FileTextSlice) -> FileContent {
        if slice.isBinary { return .binary(totalBytes: slice.totalBytes) }
        var text = slice.content
        // Lecture coupée à 256 Kio : le dernier caractère peut être un caractère multi-octets coupé (U+FFFD).
        if slice.truncated, text.last == "\u{FFFD}" { text.removeLast() }
        return .text(lines: text.textLines.map(\.clippedForDisplay), truncated: slice.truncated, totalBytes: slice.totalBytes)
    }

    /// Recherche floue de l'hôte dans le projet ; une requête plus récente rend caduques les réponses en vol. Les
    /// fichiers cachés sont retirés tant qu'ils sont masqués (l'hôte, lui, ne masque rien).
    public func search(_ query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = []
            searchFailure = nil
            return
        }
        guard let channel = await connection.ensureConnected() else {
            guard generation == searchGeneration else { return }
            searchFailure = connection.failure?.message ?? "Hôte injoignable."
            return
        }
        do {
            let results = try await FileClient(client: channel).search(root: root, query: query)
            guard generation == searchGeneration else { return }
            searchResults = showsHidden ? results : results.filter { match in
                !match.relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
            }
            searchFailure = nil
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchFailure = WorkspaceErrors.message(error)
        }
    }
}
