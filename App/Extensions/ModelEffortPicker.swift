import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Choix d'un modèle et de son effort, lus du catalogue de l'hôte. Première ligne : `inheritLabel` (aucun choix, le
/// modèle par défaut). Choisir un modèle fixe l'effort au plus fort qu'il propose ; l'effort se règle ensuite, et son
/// sélecteur disparaît pour un modèle qui n'en propose pas. À placer dans un `Form` ou une `List`.
struct ModelEffortPicker: View {
    @Binding var selection: ModelSelection?
    let catalog: ModelSelectionView?
    let inheritLabel: String
    let modelIdentifier: String
    let effortIdentifier: String

    private struct Choice: Hashable {
        let providerId: String
        let modelId: String
    }

    var body: some View {
        Picker("Modèle", selection: modelChoice) {
            Text(inheritLabel).tag(Choice?.none)
            // Choix actuel absent du catalogue ou désactivé : gardé visible, sinon le sélecteur resterait vide.
            if let selection, !isListed(selection) {
                Text(selection.modelId).tag(Choice?.some(Choice(providerId: selection.providerId, modelId: selection.modelId)))
            }
            ForEach(catalog?.providers ?? []) { provider in
                let models = provider.visibleModels
                if !models.isEmpty {
                    Section(provider.name) {
                        ForEach(models) { model in
                            Text(model.modelId).tag(Choice?.some(Choice(providerId: provider.providerId, modelId: model.modelId)))
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(modelIdentifier)
        if let levels = effortLevels, !levels.isEmpty {
            Picker("Effort", selection: effortChoice(levels)) {
                ForEach(levels, id: \.self) { Text(ChatLabels.effort($0)).tag($0) }
            }
            .accessibilityIdentifier(effortIdentifier)
        }
    }

    private func isListed(_ selection: ModelSelection) -> Bool {
        guard let catalog else { return false }
        return ModelChoice.isAvailable(selection, in: catalog)
    }

    private var modelChoice: Binding<Choice?> {
        Binding(
            get: { selection.map { Choice(providerId: $0.providerId, modelId: $0.modelId) } },
            set: { choice in
                guard let choice else { selection = nil; return }
                guard choice != self.modelChoice.wrappedValue else { return }
                guard let model = catalog?.model(providerId: choice.providerId, modelId: choice.modelId) else { return }
                selection = ModelChoice.selecting(providerId: choice.providerId, model: model)
            }
        )
    }

    /// Niveaux du modèle choisi ; `nil` sans choix ou hors catalogue.
    private var effortLevels: [String]? {
        guard let selection else { return nil }
        return catalog?.model(providerId: selection.providerId, modelId: selection.modelId)?.reasoningLevels
    }

    private func effortChoice(_ levels: [String]) -> Binding<String> {
        Binding(
            get: {
                let current = selection?.options?.reasoningLevel
                return current.flatMap { levels.contains($0) ? $0 : nil } ?? levels.last ?? ""
            },
            set: { level in
                guard var updated = selection else { return }
                updated.options = ModelSelection.Options(reasoningLevel: level)
                selection = updated
            }
        )
    }
}
