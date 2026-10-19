import Foundation
import ZCodeV4

/// Règles de choix d'un modèle pour un réglage hors conversation (sous-agents) : mêmes règles que le composeur, l'effort
/// vient du catalogue de l'hôte et jamais d'une liste codée en dur.
public enum ModelChoice {
    /// Choix d'un modèle : l'effort le plus fort qu'il propose, aucun s'il n'en propose pas.
    public static func selecting(providerId: String, model: ModelSelectionView.Model) -> ModelSelection {
        ModelSelection(providerId: providerId, modelId: model.modelId, reasoningLevel: model.reasoningLevels.last)
    }

    /// Le modèle est dans le catalogue et n'est pas désactivé sur l'hôte.
    public static func isAvailable(_ selection: ModelSelection, in view: ModelSelectionView) -> Bool {
        view.model(providerId: selection.providerId, modelId: selection.modelId)?.enabled == true
    }

    /// Pas d'effort demandé, ou un effort que le modèle propose.
    public static func supportsEffort(_ selection: ModelSelection, in view: ModelSelectionView) -> Bool {
        guard let effort = selection.options?.reasoningLevel else { return true }
        return view.model(providerId: selection.providerId, modelId: selection.modelId)?.reasoningLevels.contains(effort) == true
    }
}
