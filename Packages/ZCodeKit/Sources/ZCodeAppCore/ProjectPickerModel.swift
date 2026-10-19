import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Explorateur de dossiers de l'hôte pour choisir un projet (lot 13H) : part du home de l'hôte (parent du
/// premier projet annoncé par `server-info`, repli `/`), ne propose que les dossiers. L'hôte ne borne rien
/// au projet : tout chemin absolu que l'hôte renvoie est explorable.
@MainActor
@Observable
public final class ProjectPickerModel {
    public enum Listing: Equatable, Sendable {
        case loading
        case loaded([FileEntry])       // dossiers uniquement, dans l'ordre de l'hôte
        case failed(String)
    }

    public private(set) var path: String
    public private(set) var listing: Listing = .loading
    /// Faux à la racine : « Remonter » est alors inactif.
    public private(set) var canGoUp = false
    private var stack: [String] = []
    private let connection: HostConnection
    /// La racine fournie à l'init (tests) ne replie pas sur `/` si sa lecture échoue.
    private let fixedRoot: Bool
    @ObservationIgnored private var generation = 0

    public init(connection: HostConnection, root: String? = nil) {
        self.connection = connection
        if let root {
            path = root
            fixedRoot = true
        } else {
            // Le home se dérive de `server-info`, lu à la connexion : dérivé dans `start()`.
            path = "/"
            fixedRoot = false
        }
    }

    /// Dossier courant (affiché sous le titre).
    public var currentPath: String { path }

    /// Connecte l'hôte, dérive la racine (home, ou `root` fourni), charge sa liste ; si la racine dérivée
    /// est illisible, repli sur `/`.
    public func start() async {
        if connection.state != .connected {
            await connection.connect()
        }
        if !fixedRoot {
            path = Self.home(of: connection)
        }
        await load(path)
        if !fixedRoot, case .failed = listing, path != "/" {
            path = "/"
            stack = []
            canGoUp = false
            await load(path)
        }
    }

    /// Descend dans un dossier de la liste courante ; un fichier est ignoré (un projet est un dossier).
    public func descend(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        stack.append(path)
        path = entry.path
        canGoUp = true
        await load(path)
    }

    /// Remonte d'un niveau dans la pile de navigation (pas au parent calculé : un lien symbolique peut
    /// mener ailleurs).
    public func goUp() async {
        guard let parent = stack.popLast() else { return }
        path = parent
        canGoUp = !stack.isEmpty
        await load(path)
    }

    /// Relit le dossier courant (bouton « Réessayer »).
    public func reload() async {
        await load(path)
    }

    /// Home de l'hôte : parent du premier projet annoncé par `server-info` (`server-info` n'a pas de champ
    /// home ; sur les deux hôtes configurés, le parent du premier projet est le home). Repli `/`.
    static func home(of connection: HostConnection) -> String {
        guard let first = connection.serverInfo?.workspaces.first?.path, first != "/" else { return "/" }
        let parent = URL(filePath: first).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func load(_ path: String) async {
        generation += 1
        let generation = self.generation
        listing = .loading
        guard let channel = await connection.ensureConnected() else {
            guard generation == self.generation else { return }
            listing = .failed(connection.failure?.message ?? "Hôte injoignable.")
            return
        }
        do {
            let entries = try await FileClient(client: channel).readdir(path: path, includeHidden: false)
            guard generation == self.generation else { return }          // navigation pendant la lecture
            listing = .loaded(entries.filter(\.isDirectory))
        } catch {
            guard generation == self.generation else { return }
            listing = .failed(WorkspaceErrors.message(error))
        }
    }
}
