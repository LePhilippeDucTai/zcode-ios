import Foundation
import ZCodeV4

struct HostRoute: Hashable {
    let hostId: UUID
}

/// Utilisation du Coding Plan d'un hôte.
struct UsageRoute: Hashable {
    let hostId: UUID
}

/// Extensions (sous-agents, plugins) d'un hôte : `workspace` nil = portée Utilisateur, sinon le projet d'où l'on vient.
struct ExtensionsRoute: Hashable {
    let hostId: UUID
    let workspace: String?
}

/// Workflows enregistrés d'un projet.
struct WorkflowsRoute: Hashable {
    let hostId: UUID
    let workspace: String
}

struct WorkspaceRoute: Hashable {
    let hostId: UUID
    let path: String
}

struct SessionRoute: Hashable {
    let hostId: UUID
    let workspace: String
    let sessionId: String
}

/// Fil d'un sous-agent ouvert en lecture seule (lot 13D) : session enfant, titre de sa carte, type demandé.
struct SubagentContext: Hashable, Identifiable {
    let sessionId: String
    let title: String
    let subagentType: String
    var id: String { sessionId }
}

/// Modifications Git d'un projet.
struct ChangesRoute: Hashable {
    let hostId: UUID
    let workspace: String
}

/// Dossier d'un projet (`path` absolu ; le projet lui-même pour la racine).
struct DirectoryRoute: Hashable {
    let hostId: UUID
    let workspace: String
    let path: String
}

struct FileRoute: Hashable {
    let hostId: UUID
    let workspace: String
    let path: String
}

struct GitDiffRoute: Hashable {
    let hostId: UUID
    let workspace: String
    let change: GitFileChange
}

/// Fichiers modifiés d'un tour, ouverts en feuille depuis son pied.
struct TurnChangesRoute: Identifiable {
    let target: RowTarget
    var id: RowTarget { target }
}
