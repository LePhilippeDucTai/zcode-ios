import Foundation
import ZCodeV4

/// Mode proposé dans le composeur. Liste fixe (écart assumé avec la spec) : ZCode 3.15.1 ne l'expose que par le sujet
/// `workspace-config` (vide sans session active) et son interface web la code aussi (`ZCODE_AGENT_MODE_OPTIONS`).
public struct ModeOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let detail: String

    public static let plan = "plan"

    public static let all: [ModeOption] = [
        ModeOption(id: "build", label: "Demander avant de modifier", detail: "Validation avant chaque modification de fichier."),
        ModeOption(id: "guarded", label: "Autonome", detail: "Ne demande qu'en cas de risque."),
        ModeOption(id: "plan", label: "Mode plan", detail: "Explore le code et propose un plan avant de modifier."),
        ModeOption(id: "yolo", label: "Accès complet", detail: "Modifie et exécute avec moins de confirmations."),
    ]

    /// Libellé d'un mode, y compris `edit` (accepté mais non proposé) ; un mode inconnu reste affiché tel quel.
    public static func label(for id: String) -> String {
        if let option = all.first(where: { $0.id == id }) { return option.label }
        return id == "edit" ? "Modification automatique" : id
    }
}

/// Mode demandé à la création d'une session (`createSession.config`).
public struct SessionModeRequest: Equatable, Sendable {
    public let mode: String
    public let planEnabled: Bool

    public init(mode: String, planEnabled: Bool) {
        self.mode = mode
        self.planEnabled = planEnabled
    }
}

extension ModeOption {
    /// `plan` = plan actif sur « Demander avant de modifier », comme dans le composeur (`ComposerSettings.applyMode`).
    public static func sessionRequest(for id: String) -> SessionModeRequest {
        id == plan ? SessionModeRequest(mode: "build", planEnabled: true) : SessionModeRequest(mode: id, planEnabled: false)
    }

    /// Note sous le choix du mode par défaut d'un hôte (`nil` : l'hôte décide).
    public static func defaultModeNote(for id: String?) -> String {
        switch id {
        case nil: "L'hôte applique son propre défaut."
        case "yolo": "Accès complet : l'agent exécute tout sur cet hôte sans demander (suppressions, git push…)."
        default: "Appliqué aux sessions créées depuis cet iPhone ; modifiable ensuite dans le composeur."
        }
    }
}

public enum ComposerIssue: Error, Equatable, Sendable {
    case modelUnavailable(String)
    case effortUnavailable(String)

    public var message: String {
        switch self {
        case .modelUnavailable(let model): "Le modèle \(model) n'est plus proposé par l'hôte : choisis-en un autre."
        case .effortUnavailable(let level): "Niveau d'effort « \(level) » non pris en charge par ce modèle : choisis-en un autre."
        }
    }
}

/// Ce qui accompagne un message (`sendText`).
public struct ComposerSubmission: Equatable, Sendable {
    public let modelSelection: ModelSelection?
    /// Mode de permission ; jamais `plan`.
    public let mode: String
    public let planEnabled: Bool
}

/// Modèle, effort et mode du prochain message : brouillon local, le snapshot ne change qu'au démarrage du tour.
public struct ComposerSettings: Equatable, Sendable {
    public private(set) var selection: ModelSelection?
    /// `build`, `guarded`, `yolo`, `edit`… ; le plan est porté par `planEnabled`.
    public private(set) var permissionMode: String
    public private(set) var planEnabled: Bool

    public init(selection: ModelSelection?, permissionMode: String = "build", planEnabled: Bool = false) {
        self.selection = selection
        self.permissionMode = permissionMode
        self.planEnabled = planEnabled
    }

    /// Réglages de la session, sinon choix par défaut de l'hôte.
    public static func initial(config: SessionConfig?, view: ModelSelectionView?) -> ComposerSettings {
        var settings = ComposerSettings(selection: config?.modelSelection ?? view?.preferredSelection)
        settings.applyMode(config?.mode, planEnabled: config?.planEnabled)
        return settings
    }

    /// Choix par défaut de l'hôte, quand le catalogue arrive après le premier snapshot et que la session n'avait pas de modèle.
    public mutating func adoptDefaultSelection(from view: ModelSelectionView) {
        if selection == nil { selection = view.preferredSelection }
    }

    /// Mode affiché dans le sélecteur : `plan` si le plan est actif, sinon le mode de permission.
    public var displayedMode: String { planEnabled ? ModeOption.plan : permissionMode }

    /// Nouveau modèle : niveau d'effort le plus fort qu'il propose (comme l'interface web).
    public mutating func selectModel(providerId: String, modelId: String, in view: ModelSelectionView) {
        let levels = view.model(providerId: providerId, modelId: modelId)?.reasoningLevels ?? []
        selection = ModelSelection(providerId: providerId, modelId: modelId, reasoningLevel: levels.last)
    }

    public mutating func selectEffort(_ level: String) {
        guard var current = selection else { return }
        current.options = ModelSelection.Options(reasoningLevel: level)
        selection = current
    }

    /// `plan` active le plan sans toucher au mode de permission ; un autre mode le désactive.
    public mutating func selectMode(_ id: String) {
        if id == ModeOption.plan {
            planEnabled = true
        } else {
            permissionMode = id
            planEnabled = false
        }
    }

    /// Nouvelle config de session : on ne suit que ce qui a réellement changé (sinon le choix en cours est gardé).
    public mutating func realign(from previous: SessionConfig?, to current: SessionConfig?) {
        guard let current else { return }
        if current.modelSelection != previous?.modelSelection, let changed = current.modelSelection {
            selection = changed
        }
        if current.mode != previous?.mode || current.planEnabled != previous?.planEnabled {
            applyMode(current.mode, planEnabled: current.planEnabled)
        }
    }

    /// Valide le choix contre le catalogue de l'hôte (s'il est chargé) et complète un niveau absent.
    public func submission(in view: ModelSelectionView?) -> Result<ComposerSubmission, ComposerIssue> {
        guard var selection else {
            return .success(ComposerSubmission(modelSelection: nil, mode: permissionMode, planEnabled: planEnabled))
        }
        if let view {
            guard let model = view.model(providerId: selection.providerId, modelId: selection.modelId), model.enabled else {
                return .failure(.modelUnavailable(selection.modelId))
            }
            if let level = selection.options?.reasoningLevel {
                if !model.reasoningLevels.isEmpty, !model.reasoningLevels.contains(level) {
                    return .failure(.effortUnavailable(level))
                }
            } else if let strongest = model.reasoningLevels.last {
                // ZCode exige un niveau (« Reasoning level is required »).
                selection.options = ModelSelection.Options(reasoningLevel: strongest)
            }
        }
        return .success(ComposerSubmission(modelSelection: selection, mode: permissionMode, planEnabled: planEnabled))
    }

    private mutating func applyMode(_ mode: String?, planEnabled: Bool?) {
        if mode == ModeOption.plan {
            permissionMode = "build"
            self.planEnabled = true
        } else {
            permissionMode = mode ?? "build"
            self.planEnabled = planEnabled ?? false
        }
    }
}
