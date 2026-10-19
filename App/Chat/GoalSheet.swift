import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Fiche de lancement d'un Goal (bouton « Goal » du composeur).
struct GoalSheet: View {
    let conversation: ConversationModel
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var queueItemIds: [String]?

    private var trimmed: String { objective.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Objectif", text: $objective, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("goal-objective")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Le Goal continue jusqu'à ce qu'il soit atteint ou mis en pause ; chaque itération consomme des appels au modèle.")
                        if let goal = conversation.goal, goal.status != .verified {
                            Text("Un Goal en cours sera remplacé.")
                        }
                    }
                }
                if let error = conversation.commandError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button { Task { await start() } } label: {
                        HStack {
                            Text("Lancer le Goal")
                            if conversation.sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(trimmed.isEmpty || conversation.sending)
                    .accessibilityIdentifier("goal-start")
                }
            }
            .navigationTitle("Nouveau Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
            .confirmationDialog("Lancer le Goal ?", isPresented: Binding(get: { queueItemIds != nil }, set: { if !$0 { queueItemIds = nil } }),
                                titleVisibility: .visible, presenting: queueItemIds) { itemIds in
                Button("Vider la file et lancer", role: .destructive) {
                    Task { await start(heldQueue: .init(.clearQueueAndSend, expectedItemIds: itemIds)) }
                }
                Button("Garder la file et lancer") {
                    Task { await start(heldQueue: .init(.keepQueueAndSend, expectedItemIds: itemIds)) }
                }
            } message: { itemIds in
                Text(itemIds.count == 1 ? "Un message attend dans la file." : "\(itemIds.count) messages attendent dans la file.")
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { conversation.dismissCommandError() }
    }

    private func start(heldQueue: CommandBuilder.HeldQueueChoice? = nil) async {
        switch await conversation.startGoal(trimmed, heldQueue: heldQueue) {
        case .sent, .unconfirmed:
            dismiss()
        case .needsQueueChoice(let itemIds):
            queueItemIds = itemIds
        case .failed:
            break                                              // l'erreur est affichée, l'objectif reste dans la fiche
        }
    }
}
