import SwiftUI
import ZCodeAppCore

struct ChatView: View {
    let host: Host
    let route: SessionRoute
    /// Non nil : fil d'un sous-agent, ouvert en lecture seule (lot 13D).
    var subagent: SubagentContext? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var slashTokens = SlashTokens()
    @State private var showingWeb = false
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var atBottom = true
    @State private var deleteError: String?
    @State private var changesTarget: TurnChangesRoute?
    @State private var renaming: RenameTarget?
    /// Largeur de l'écran, pour borner le titre de la barre (voir `ChatTitleMenu.reservedWidth`).
    @State private var screenWidth: CGFloat = 0
    /// Recherche dans la conversation (menu « ⋯ ») ; la sélection courante est surlignée un instant.
    @State private var searching = false
    @State private var searchText = ""
    @State private var search = ConversationSearch()
    @State private var searchingOlder = false
    /// Correspondance dans un groupe replié : défilement différé jusqu'à ce que sa cellule existe.
    @State private var pendingScrollId: Int?
    @State private var olderNote: String?
    @State private var highlighted: Int?
    @State private var gallery: ImageGallery?
    /// Session dérivée par « Repartir d'ici », ouverte par-dessus.
    @State private var forkedSession: String?
    /// Fil d'un sous-agent ouvert par « Voir le fil ».
    @State private var openedSubagent: SubagentContext?
    /// Liste des sous-agents en cours (feuille tenue ici : la puce disparaît quand le dernier sous-agent se termine).
    @State private var showingRunningSubagents = false

    private var readOnly: Bool { subagent != nil }

    var body: some View {
        let conversation = model.conversation(for: host, workspace: route.workspace, sessionId: route.sessionId,
                                              readOnly: readOnly)
        let title: String = conversation.title ?? subagent?.title ?? "Session"
        let location: String = subagent.map { $0.subagentType.isEmpty ? "Sous-agent" : "Sous-agent · \($0.subagentType)" }
            ?? ChatLabels.location(hostName: host.name, workspace: route.workspace)
        let locked = conversation.isLocked
        let renameAction = renameAction(locked: locked)
        content(conversation)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(title: title, location: location, locked: locked, rename: renameAction) }
        .sheet(isPresented: $showingWeb) {
            WebFallbackView(url: model.webInterfaceURL(for: host))
        }
        .sheet(item: $changesTarget) { changes in
            TurnChangesView(conversation: conversation, host: host, workspace: route.workspace, target: changes.target)
        }
        .sheet(isPresented: $showingRunningSubagents) {
            RunningSubagentsSheet(subagents: conversation.runningSubagents, open: { openedSubagent = $0 })
        }
        .fullScreenCover(item: $gallery) { gallery in
            ImageViewer(gallery: gallery, loader: AttachmentLoader { await conversation.attachmentData(for: $0) })
        }
        .renameSessionAlert(host: host, workspace: route.workspace, target: $renaming)
        .alert("Archivage impossible", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task {
            if !readOnly {
                model.conversationDidAppear(host: host, workspace: route.workspace, sessionId: route.sessionId)
            }
            await conversation.startIfNeeded()
        }
        // Catalogue « / » relu à l'ouverture (s'il a plus de 5 minutes) puis à chaque changement d'autorité : la lecture
        // de session attend un premier snapshot (l'hôte refuse -32004 avant l'abonnement).
        .task(id: conversation.skillsCatalogSessionId) {
            guard !readOnly else { return }
            await model.slashCatalog(for: host, workspace: route.workspace)
                .refreshIfNeeded(sessionId: conversation.skillsCatalogSessionId)
        }
        .onDisappear {
            if !readOnly {
                model.conversationDidDisappear(host: host, workspace: route.workspace, sessionId: route.sessionId)
            }
            Task { await conversation.stop() }
        }
    }

    /// Pas de renommage dans le fil d'un sous-agent ni sur une copie hors ligne.
    private func renameAction(locked: Bool) -> (() -> Void)? {
        locked ? nil : { startRenaming() }
    }

    /// Liste, recherche, bandeaux et navigation vers les fils ouverts depuis la conversation.
    private func content(_ conversation: ConversationModel) -> some View {
        let showGallery = $gallery
        let openFork = $forkedSession
        let openSubagent = $openedSubagent
        let forkAction = conversation.isLocked ? MessageForkAction() : MessageForkAction { rowId in
            Task { if let child = await conversation.fork(rowId: rowId) { openFork.wrappedValue = child } }
        }
        let forkable = conversation.forkableRowIds
        // Première entrée, quelle qu'elle soit (carte de run comprise, id négatif) : pas de marge de début de tour.
        let firstEntryId = conversation.entries.first?.id
        return ScrollView {
            // Une cellule par entrée : conserver les identifiants de ligne pour le streaming et la pagination.
            LazyVStack(alignment: .leading, spacing: 8) {
                if conversation.hasOlderRows {
                    if conversation.olderRowsFailed {
                        // Pas d'`onAppear` ici : une page en échec ne doit pas être retentée en boucle.
                        Button("Impossible de charger les messages précédents — Réessayer") {
                            Task { await loadOlder(conversation) }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear { Task { await loadOlder(conversation) } }
                    }
                }
                ForEach(conversation.entries) { entry in
                    ChatEntryView(entry: entry, canRetry: entry.id == conversation.retryEntryId,
                                  canFork: forkable.contains(entry.id),
                                  openChanges: { changesTarget = TurnChangesRoute(target: $0) },
                                  retry: { Task { await conversation.retryLastResponse() } },
                                  stopWorkflowRun: { runId in Task { await conversation.cancelWorkflowRun(runId) } },
                                  toggleToolGroup: { conversation.toggleToolGroup($0) })
                        .equatable()
                        .background(Color.yellow.opacity(highlighted == entry.id ? 0.28 : 0),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .animation(.easeInOut(duration: 0.3), value: highlighted == entry.id)
                        .padding(.top, entry.startsTurn && entry.id != firstEntryId ? 10 : 0)
                        .id(entry.id)
                }
                ForEach(conversation.guideItems, id: \.queueItemId) { item in
                    PendingGuideBubble(text: item.text)
                        .padding(.top, 8)
                }
            }
            .scrollTargetLayout()
            .padding()
        }
        .accessibilityIdentifier("chat-list")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        .environment(\.attachmentLoader, AttachmentLoader { await conversation.attachmentData(for: $0) })
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        // Suivent le réglage système des vibrations ; jamais sur `contentVersion` (un changement par delta).
        .sensoryFeedback(.success, trigger: conversation.finishedTurns)
        .sensoryFeedback(.warning, trigger: conversation.newInteractionAlerts)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
        } action: { _, isAtBottom in
            atBottom = isAtBottom
        }
        .onChange(of: conversation.contentVersion) {
            // Delta ou page plus ancienne : correspondances recalculées, sélection gardée sur la même entrée.
            if searching { search.refresh(entries: conversation.ungroupedEntries) }
            // On ne suit la réponse que si l'utilisateur est déjà en bas (il peut relire plus haut).
            // `edge: .bottom` : résolu sur la taille réelle du contenu (cellule qui grandit, guides en attente, marge de 16 pt).
            guard atBottom else { return }
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: searchText) {
            search.update(query: searchText, entries: conversation.ungroupedEntries)
            olderNote = nil
        }
        .onChange(of: search.currentId) { _, id in
            guard let id else { return }
            if conversation.entries.contains(where: { $0.id == id }) {
                withAnimation { position.scrollTo(id: id, anchor: .center) }
                flash(id)
            } else {
                // Dans un groupe replié : le déplier, puis défiler quand `entries` contient la cellule.
                pendingScrollId = id
                conversation.reveal(entryId: id)
            }
        }
        .onChange(of: conversation.entries.map(\.id)) { _, ids in
            guard let id = pendingScrollId, ids.contains(id) else { return }
            pendingScrollId = nil
            withAnimation { position.scrollTo(id: id, anchor: .center) }
            flash(id)
        }
        .overlay { emptyOverlay(conversation) }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if searching {
                    ChatSearchBar(text: $searchText, counter: search.counter, canMove: !search.matches.isEmpty,
                                  canSearchOlder: search.counter != nil && conversation.hasOlderRows,
                                  searchingOlder: searchingOlder, olderNote: olderNote,
                                  previous: { search.previous() }, next: { search.next() },
                                  searchOlder: { Task { await searchOlder(conversation) } },
                                  close: closeSearch)
                }
                durationsRow(conversation)
                if let goal = conversation.goal {
                    GoalBanner(conversation: conversation, goal: goal).padding(.vertical, 4)
                }
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) { bottomBar(conversation) }
        .environment(\.openImageGallery, ImageGalleryOpener { showGallery.wrappedValue = $0 })
        .environment(\.messageFork, forkAction)
        .environment(\.openSubagent, SubagentOpenAction { openSubagent.wrappedValue = $0 })
        .navigationDestination(item: $forkedSession) { sessionId in
            ChatView(host: host, route: SessionRoute(hostId: host.id, workspace: route.workspace, sessionId: sessionId))
        }
        .navigationDestination(item: $openedSubagent) { child in
            // Même hôte, même dossier que le parent : l'enfant n'est pas dans l'index, il se lit par son seul identifiant.
            ChatView(host: host, route: SessionRoute(hostId: host.id, workspace: route.workspace, sessionId: child.sessionId),
                     subagent: child)
        }
    }

    /// Durées de la session ; la puce des sous-agents en cours n'existe (et ne prend de place) que s'il y en a.
    /// Structure fixe (toujours le même `HStack`) : la barre garde son état quand la puce apparaît ou disparaît.
    @ViewBuilder private func durationsRow(_ conversation: ConversationModel) -> some View {
        let running = conversation.runningSubagents
        HStack(spacing: 8) {
            SessionDurationsBar(work: conversation.workTime, host: host, workspace: route.workspace,
                                sessionId: route.sessionId)
            if !running.isEmpty {
                RunningSubagentsChip(count: running.count) { showingRunningSubagents = true }
            }
        }
        .padding(.horizontal, running.isEmpty ? 0 : 12)
    }

    @ToolbarContentBuilder private func toolbarContent(title: String, location: String, locked: Bool,
                                                       rename: (() -> Void)?) -> some ToolbarContent {
        // Titre maison plutôt que `navigationSubtitle` + `toolbarTitleMenu` : avec ceux-ci, iOS 26 garde un titre
        // long en entier et range jauge et menu « ⋯ » dans le débordement de la barre ; ici, le titre se tronque.
        ToolbarItem(placement: .principal) {
            ChatTitleMenu(title: title, location: location,
                          hostName: host.name, workspace: route.workspace,
                          width: max(ChatTitleMenu.minimumWidth, screenWidth - ChatTitleMenu.reservedWidth),
                          rename: rename)
        }
        // Un seul groupe à droite : en `.primaryAction` séparés, iOS 26 rangeait la jauge dans le menu de
        // débordement de la barre (titre et sous-titre prennent la place).
        ToolbarItemGroup(placement: .topBarTrailing) {
            UsageButton(host: host)
            Menu {
                Button { searching = true } label: {
                    Label("Rechercher dans la conversation", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("chat-search")
                if !locked {
                    Button { startRenaming() } label: { Label("Renommer la session", systemImage: "pencil") }
                        .accessibilityIdentifier("chat-rename")
                    Button { showingWeb = true } label: { Label("Ouvrir dans l'interface web", systemImage: "safari") }
                    Button(role: .destructive) { Task { await archive() } } label: {
                        Label("Archiver la conversation", systemImage: "archivebox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("chat-menu")
        }
    
    }

    /// Conversation vide : chargement, ou invitation (texte propre au fil d'un sous-agent).
    @ViewBuilder private func emptyOverlay(_ conversation: ConversationModel) -> some View {
        if conversation.entries.isEmpty {
            if conversation.phase == .loading || conversation.phase == .idle {
                ProgressView("Chargement de la conversation…")
            } else if conversation.phase == .ready, readOnly {
                ContentUnavailableView("Rien pour l'instant", systemImage: "person.2",
                                       description: Text("Le sous-agent n'a encore rien écrit."))
            } else if conversation.phase == .ready {
                ContentUnavailableView("Nouvelle conversation", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Écris un premier message à ZCode."))
            }
        }
    }

    /// Pied de l'écran : bannières, puis composeur (ou rien en lecture seule).
    @ViewBuilder private func bottomBar(_ conversation: ConversationModel) -> some View {
        VStack(spacing: 6) {
            if conversation.isLocked {
                // Copie hors ligne : erreurs, avis et envois non confirmés restent visibles ; pas le composeur.
                ChatBanners(conversation: conversation, readOnly: readOnly) { showingWeb = true }
            } else {
                ChatBanners(conversation: conversation) { showingWeb = true }
                QueuePanel(conversation: conversation)
                if let interaction = conversation.currentInteraction {
                    // Le composeur est remplacé, pas son brouillon : `draft` vit ici et revient intact après la réponse.
                    InteractionDock(conversation: conversation, interaction: interaction)
                } else {
                    ComposerView(conversation: conversation, host: host, draft: $draft, tokens: $slashTokens)
                }
            }
        }
        .padding(.top, 6)
        .background(.bar)
    }

    private func startRenaming() {
        let conversation = model.conversation(for: host, workspace: route.workspace, sessionId: route.sessionId,
                                              readOnly: readOnly)
        renaming = RenameTarget(sessionId: route.sessionId, currentTitle: conversation.title)
    }

    private func closeSearch() {
        searching = false
        searchText = ""
        search = ConversationSearch()
        olderNote = nil
        highlighted = nil
        pendingScrollId = nil
    }

    /// Surligne l'entrée trouvée 1,5 s (l'entrée entière, pas le mot).
    private func flash(_ id: Int) {
        highlighted = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if highlighted == id { highlighted = nil }
        }
    }

    /// « Chercher plus loin » : historique plus ancien, 10 pages au plus par geste.
    private func searchOlder(_ conversation: ConversationModel) async {
        searchingOlder = true
        defer { searchingOlder = false }
        olderNote = nil
        switch await conversation.searchOlder(search.query) {
        case .found(let id):
            search.refresh(entries: conversation.ungroupedEntries)
            search.select(id)
        case .exhausted:
            olderNote = "Début de la conversation : rien de plus ancien."
        case .limitReached:
            olderNote = "Rien dans les \(ConversationModel.searchPagesPerGesture) pages précédentes."
        case .failed:
            olderNote = "Historique indisponible : réessaie."
        }
    }

    /// Archive sans confirmation (retrouvable dans « Sessions archivées ») et revient à la liste.
    private func archive() async {
        do {
            try await model.archiveSession(host: host, workspace: route.workspace, sessionId: route.sessionId)
            dismiss()
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ajoute la page précédente sans faire sauter la lecture : on revient sur l'entrée qui était en haut.
    private func loadOlder(_ conversation: ConversationModel) async {
        let anchor = conversation.entries.first { $0.id >= 0 }?.id
        await conversation.loadOlder()
        // Rien n'a été ajouté en cas d'échec : on ne ramène pas le lecteur en haut.
        if let anchor, !conversation.olderRowsFailed { position.scrollTo(id: anchor, anchor: .top) }
    }
}

/// Titre de la conversation (tronqué si long) et « hôte · dossier » dessous ; ouvre le menu du titre.
private struct ChatTitleMenu: View {
    /// Place laissée au bouton retour (16 + 44 pt) et au groupe jauge + menu « ⋯ » (≈ 104 + 16 pt), marges comprises :
    /// la vue principale prend sinon sa largeur idéale et passe sous les boutons au lieu de se tronquer. Largeur fixe,
    /// posée sur le libellé du menu : la barre et `Menu` demandent la taille idéale, qu'un cadre extérieur ne borne pas.
    static let reservedWidth: CGFloat = 200
    static let minimumWidth: CGFloat = 120
    let title: String
    let location: String
    let hostName: String
    let workspace: String
    let width: CGFloat
    let rename: (() -> Void)?

    var body: some View {
        Menu {
            if let rename {
                Button(action: rename) { Label("Renommer", systemImage: "pencil") }
            }
            Section("\(hostName) — dossier du projet") {
                Button {
                    UIPasteboard.general.string = workspace
                } label: {
                    Label(workspace, systemImage: "doc.on.doc")
                }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(ZCodeTypography.navigationTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width)
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(title)
        .accessibilityValue(location)
        .accessibilityIdentifier("chat-title")
    }
}
