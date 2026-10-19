import SwiftUI
import ZCodeAppCore
import ZCodeV4

struct ComposerView: View {
    let conversation: ConversationModel
    let host: Host
    @Binding var draft: String
    /// Jetons insérés par le panneau « / » : tenus par `ChatView` avec le brouillon (le dock d'interaction remplace le
    /// composeur sans les perdre).
    @Binding var tokens: SlashTokens

    private struct QueueChoice: Identifiable {
        let id = UUID()
        let text: String
        let itemIds: [String]
    }

    @State private var choice: QueueChoice?
    @State private var showingGoal = false
    @State private var showingUsage = false
    @State private var selection: TextSelection?
    /// Mot fermé par « Fermer » : le panneau reste fermé tant que ce mot ne change pas.
    @State private var dismissedTrigger: SlashTrigger?
    /// Un envoi vide le brouillon : la table des jetons n'est pas effacée pour autant (elle l'est à la fin de l'envoi).
    @State private var sendingDraft = false
    @Environment(AppModel.self) private var model

    private var text: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Quelque chose à envoyer : du texte ou au moins une pièce jointe.
    private var hasContent: Bool { !text.isEmpty || !conversation.attachments.isEmpty }

    private var catalog: SlashCatalog { model.slashCatalog(for: host, workspace: conversation.workspace) }

    /// Mot « / » sous le curseur ; aucun quand l'hôte refuse toute saisie.
    private var trigger: SlashTrigger? {
        guard conversation.routing != "reject", let split = ComposerCursor.split(draft, selection) else { return nil }
        return SlashInput.activeTrigger(before: split.before)
    }

    var body: some View {
        let trigger = self.trigger
        return VStack(spacing: 6) {
            if let trigger, trigger != dismissedTrigger {
                SlashPanel(sections: catalog.sections(query: trigger.query, sessionId: conversation.skillsCatalogSessionId),
                           loading: catalog.isLoading, pick: apply, close: { dismissedTrigger = trigger })
            }
            ComposerSelectors(conversation: conversation,
                              quota: UsageLabels.composerQuota(model.usage(for: host).snapshot),
                              startGoal: { showingGoal = true },
                              openUsage: { showingUsage = true })
            AttachmentStrip(conversation: conversation)
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentPicker(conversation: conversation, draft: $draft)
                TextField("Message", text: $draft, selection: $selection, axis: .vertical)
                    .font(ZCodeTypography.body)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(conversation.routing == "reject")
                    .accessibilityIdentifier("composer-field")
                if conversation.canStop && !hasContent {
                    Button { Task { await conversation.stopTurn() } } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                    .accessibilityLabel("Arrêter")
                    .accessibilityIdentifier("composer-stop")
                } else {
                    Button { Task { await send() } } label: {
                        Image(systemName: conversation.routing == "enqueue" ? "text.badge.plus" : "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(!hasContent || !conversation.canSendAttachments || conversation.sending || conversation.routing == "reject")
                    .accessibilityLabel(ChatLabels.sendLabel(routing: conversation.routing))
                    .accessibilityIdentifier("composer-send")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingGoal) { GoalSheet(conversation: conversation) }
        .sheet(isPresented: $showingUsage) { UsageSheet(host: host, isPresented: $showingUsage) }
        .onChange(of: conversation.returnedDraft) { restoreReturnedDraft() }
        .onAppear { restoreReturnedDraft() }
        .onChange(of: trigger != nil) { _, open in
            guard open else { return }
            // Comme le web, qui lit les skills quand le « / » s'ouvre : relecture si le catalogue a plus de 5 minutes.
            Task { await catalog.refreshIfNeeded(sessionId: conversation.skillsCatalogSessionId) }
        }
        .onChange(of: trigger) { _, current in
            // Le mot fermé a disparu ou changé : effacer puis retaper « / » rouvre le panneau.
            if current != dismissedTrigger { dismissedTrigger = nil }
        }
        .onChange(of: draft) { _, text in
            if text.isEmpty, !sendingDraft { tokens.removeAll() }           // brouillon supprimé : table vidée
        }
        .confirmationDialog("Envoyer le message ?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                            titleVisibility: .visible, presenting: choice) { pending in
            Button("Vider la file et envoyer", role: .destructive) {
                Task { await send(pending.text, heldQueue: .init(.clearQueueAndSend, expectedItemIds: pending.itemIds)) }
            }
            Button("Garder la file et envoyer") {
                Task { await send(pending.text, heldQueue: .init(.keepQueueAndSend, expectedItemIds: pending.itemIds)) }
            }
            Button("Annuler", role: .cancel) { if draft.isEmpty { draft = pending.text } }
        } message: { pending in
            Text(pending.itemIds.count == 1 ? "Un message attend dans la file." : "\(pending.itemIds.count) messages attendent dans la file.")
        }
    }

    private func send(_ override: String? = nil, heldQueue: CommandBuilder.HeldQueueChoice? = nil) async {
        let typed = override ?? text
        sendingDraft = true
        defer { sendingDraft = false }
        draft = ""
        selection = nil
        dismissedTrigger = nil
        switch await conversation.send(tokens.expand(typed), heldQueue: heldQueue) {
        case .sent, .unconfirmed:
            tokens.removeAll()                                 // `.unconfirmed` : renvoyé tel quel à la reprise si besoin
        case .failed:
            if draft.isEmpty { draft = typed }                 // refusé : le texte tapé (jetons compris) revient
        case .needsQueueChoice(let itemIds):
            // Le brouillon revient tout de suite : un dialogue fermé sans passer par « Annuler » ne perd pas le message.
            // Les boutons de choix le vident à nouveau en renvoyant `pending.text`, développé au renvoi.
            if draft.isEmpty { draft = typed }
            choice = QueueChoice(text: typed, itemIds: itemIds)
        }
    }

    /// Ligne du panneau touchée : le mot en cours est remplacé, le curseur posé après l'espace ajoutée.
    private func apply(_ entry: SlashEntry) {
        guard let split = ComposerCursor.split(draft, selection),
              let result = SlashInput.replace(before: split.before, after: split.after, with: entry.insertion) else { return }
        draft = result.text
        selection = TextSelection(insertionPoint: result.text.index(result.text.startIndex, offsetBy: result.cursor))
        if let sendAs = entry.sendAs { tokens.record(entry.insertion, sendAs: sendAs) }
    }

    /// Texte d'un envoi abandonné après coup (refusé par l'hôte au rapprochement) : remis dans le brouillon, sans écraser
    /// ce que l'utilisateur a déjà commencé à écrire.
    private func restoreReturnedDraft() {
        guard let returned = conversation.takeReturnedDraft() else { return }
        draft = draft.isEmpty ? returned : returned + "\n\n" + draft
    }
}

/// Modèle, effort et mode du prochain message (brouillon : la session ne change qu'au démarrage du tour).
struct ComposerSelectors: View {
    let conversation: ConversationModel
    /// Rappel du quota : anneaux 5 h et semaine (`nil` : masqué).
    var quota: ComposerQuota?
    /// Ouvre la fiche de lancement d'un Goal.
    var startGoal: () -> Void = {}
    /// Ouvre l'écran « Utilisation ».
    var openUsage: () -> Void = {}

    var body: some View {
        if let settings = conversation.settings {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let quota {
                        Button(action: openUsage) { QuotaRings(quota: quota) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(quota.accessibilityLabel)
                            .accessibilityIdentifier("composer-quota")
                    }
                    // Le Goal reste accessible directement (identifiant conservé pour les tests UI).
                    if !settings.planEnabled {
                        Button(action: startGoal) {
                            Image(systemName: "target")
                                .font(ZCodeTypography.control)
                                .frame(width: 34, height: 30)
                                .background(.quaternary.opacity(0.45), in: Capsule())
                        }
                        .accessibilityLabel("Démarrer un Goal")
                        .accessibilityIdentifier("composer-goal")
                    }
                    modelMenu(settings)
                    modeMenu(settings)
                    effortMenu(settings)
                }
                .padding(.horizontal)
            }
        }
    }

    private func modelMenu(_ settings: ComposerSettings) -> some View {
        Menu {
            if let view = conversation.catalog?.view {
                ForEach(view.providers) { provider in
                    Section(provider.name) {
                        ForEach(provider.visibleModels) { model in
                            Button {
                                conversation.selectModel(providerId: provider.providerId, modelId: model.modelId)
                            } label: {
                                let selected = settings.selection?.providerId == provider.providerId
                                    && settings.selection?.modelId == model.modelId
                                if selected { Label(model.modelId, systemImage: "checkmark") } else { Text(model.modelId) }
                            }
                        }
                    }
                }
            } else {
                Text(conversation.catalog?.failure ?? "Liste des modèles en cours de chargement…")
            }
        } label: {
            Chip(text: settings.selection?.modelId ?? "Modèle par défaut", systemImage: "cpu")
        }
        .accessibilityIdentifier("composer-model")
    }

    @ViewBuilder private func effortMenu(_ settings: ComposerSettings) -> some View {
        let levels = conversation.effortLevels
        let current = settings.selection?.options?.reasoningLevel ?? levels.last
        if levels.count > 1 {
            Menu {
                ForEach(levels, id: \.self) { level in
                    Button { conversation.selectEffort(level) } label: {
                        if level == current {
                            Label(ChatLabels.effort(level), systemImage: "checkmark")
                        } else {
                            Text(ChatLabels.effort(level))
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(ZCodeTypography.control)
                    .frame(width: 34, height: 30)
                    .background(.quaternary.opacity(0.45), in: Capsule())
            }
            .accessibilityLabel("Effort de réflexion : \(current.map(ChatLabels.effort) ?? "Par défaut")")
            .accessibilityIdentifier("composer-effort")
        } else if let only = levels.first ?? current {
            Image(systemName: "slider.horizontal.3")
                .font(ZCodeTypography.control)
                .foregroundStyle(.tertiary)
                .frame(width: 34, height: 30)
                .accessibilityLabel("Effort de réflexion : \(ChatLabels.effort(only))")
                .accessibilityIdentifier("composer-effort")
        }
    }

    private func modeMenu(_ settings: ComposerSettings) -> some View {
        Menu {
            ForEach(ModeOption.all) { option in
                Button { conversation.selectMode(option.id) } label: {
                    if option.id == settings.displayedMode {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                    Text(option.detail)
                }
            }
        } label: {
            Chip(text: ModeOption.label(for: settings.displayedMode), systemImage: "hand.raised.square")
        }
        .accessibilityIdentifier("composer-mode")
    }
}

struct Chip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(ZCodeTypography.metadata)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Capsule().fill(.quaternary.opacity(0.45)))
    }
}
