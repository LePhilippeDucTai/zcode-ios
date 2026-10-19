# ZCode iOS

Native iOS client (SwiftUI) for **ZCode** (Z.ai's coding agent, `zai-org/ZCode`). The app drives a `zcode --web` server
running on one of your own hosts (a macOS host, a Linux host such as SteamOS) and reaches it over Tailscale.
It **never** talks to model APIs directly: all GLM/Mistral traffic leaves from ZCode on the host.

Overview: `README.md`. Known limitations: `docs/limitations.md`.

## Architecture

- `Packages/ZCodeKit` — protocol stack, testable on macOS with `swift test`:
  `ZCodeWire` (13-byte frames + tag/VQL serializer) → `ZCodeRPC` (channels 100–103 / 200–204)
  → `ZCodeV4` → `ZCodeClient`. Each layer depends only on the previous one.
  - `ZCodeV4` (pure, no I/O): `WireAssembler` (fragments/CRC32), tolerant `ConversationRow`/`ConversationSnapshot`/
    `SessionsIndex`, `TopicStore` (seq/resync rules §3.3, effects to execute), `CommandBuilder` (UUIDv7, CAS).
  - `ZCodeClient`: `AgentV4` (typed facade + handshake) and `TopicFeed` (actor that wires RPC listening → store),
    plus `WebSocketTransport`, `ZCodeConnector`, `ServerInfo`, `GitClient` (`git` channel: status, diff, stage /
    discard / commit / push / branch actions, commit message generation), `FileClient` (`file` channel, read-only),
    `UsageStatsClient` (`usage-stats` channel: quotas and subscription of an account-based provider's Coding Plan;
    plan resets — status of granted opportunities, eligibility request, consumption by type with a UUID idempotency
    key ≤ 64 characters, history marked as read),
    `TaskArchiveClient` (`zcode-task` channel: archiving conversations in the host's task index —
    `taskId` = session id) and `ComposerCatalogClient` (project commands on `zcode-session`, skills on `zcode-agent`,
    dynamic-workflow entitlement on `coding-plan-subscription`; all read-only). Absolute paths: the host does not
    restrict anything to the project.
- `Packages/ZCodeKit/Sources/ZCodeAppCore` — app logic, the only package target that is `@MainActor @Observable`,
  tested by `swift test` with `FakeZCodeServer`:
  - `HostStore`, `Host.defaultMode` (mode for new sessions, sent in `createSession.config`; `nil` = « Défaut de
    l'hôte » ("Host default"), nothing sent), `HostConnection`.
  - `SessionsModel` (live list, creation; the dynamic-workflow entitlement is added to `createSession` by the host,
    never by the app). « Archiver » ("Archive"; swipe or conversation menu, no confirmation; row hidden as soon as the
    gesture happens, restored if the host refuses) = archiving through `zcode-task`: the conversation disappears from
    the list — negative join with `listArchivedTasks` / `listDeletedTaskIds` — and is permanently deleted after the
    30-day `archiveRetention`, dates kept by `ArchiveStore` on the iPhone. Closing is best effort:
    `proto.sessionNotFound` is not an error, it just means the session is not loaded on the host.
  - `SeenStore` ("unread" dot: last activity seen per session, per-project baseline on first load, open
    conversations are never unread, "seen" also set when going to background via `AppModel.sceneDidEnterBackground`;
    UserDefaults `zcode-seen:v1` via `LocalPersistence`), `PinStore` (pins, `zcode-pins:v1`), `PromptStore` (favourite
    prompts shared by all hosts, `zcode-prompts:v1` via `LocalPersistence`).
  - `SessionListLayout` (sections « En attente de vous » / « Épinglées » / « Récentes » — "Waiting for you" / "Pinned" /
    "Recent"; search ignoring case and diacritics, « Sans titre » ("Untitled") included).
  - `ConversationModel` (one `TopicFeed<ConversationSnapshot>` per session; subscription closed when the screen
    disappears; reconciliation of sends cut by the network or with an unreadable response; current request
    `currentInteraction`, an answer is never re-sent on its own; `finishedTurns` / `newInteractionAlerts` (haptics for a
    successfully finished turn and for a new request, never on the first state of a subscription)).
  - `InteractionForms` (answers to questions, plans and permissions, following ZCode web UI rules), `ModelCatalog` and
    `ComposerSettings` (model / effort / mode read from the server).
  - Composer: `SlashCatalog` (per host and project in `AppModel.slashCatalog(for:workspace:)`, re-read after
    5 minutes; a failing source drops its section), `SlashSuggestions` / `SlashMarkdown` (rules of the ZCode Web
    panel), `SlashInput` ("/" word), `SlashTokens` (tokens replaced on send), `SlashSendCommand` (`/plan`, `/compact`),
    `ChatTimeline` (rows → flat `ChatEntry`, ids derived from `rowId`; `ConversationModel.entries`),
    `ChatItem.copyableText` / `ToolCall.shellCommand` (copied text: Markdown source of a message, shell command only),
    `Reasoning.showsMarkdown` (reasoning rendered as Markdown once frozen, `MarkdownText(style: .reasoning)`: one size
    below answers, in grey), `AppModel` (root; injectable `now` clock).
  - Reading: `SyntaxHighlighter` (dependency-free highlighting: Swift, TypeScript/JavaScript, Python, shell, JSON,
    Rust, Go; plain text beyond 20,000 characters or for an unknown language; colours in `ZCodeSyntaxColors`,
    `App/Support/DesignSystem.swift`), `ConversationSearch` (search in loaded rows: messages, answers, tool name and
    command or path; selection kept per entry) and `ConversationModel.searchOlder` (« Chercher plus loin », "Search
    further": at most 10 pages per gesture), `ImageGallery` (images of a message or of the composer for the full-screen
    viewer, documents excluded), `LinePreview` (`String.linePreview(maxLines:)`: first 12 lines of a tool's command,
    input or output and the number of hidden lines).
  - Tool grouping: `ToolFamily` / `ToolGroup` (`ToolGroup.swift`: families and summary « A réfléchi, exécuté
    2 commandes · 1 échec » ("Thought, ran 2 commands · 1 failure"), total duration),
    `ChatTimeline.grouping(_:expanded:pendingInteractionIds:)` (at least two consecutive tool cards or reasoning items
    of the same row group ⇒ one `.toolGroup` entry, identity = `rowId` of the first item; still visible under a
    collapsed group: running tool, failed tool, tool awaiting permission or whose request is open, Agent card of a
    sub-agent, reasoning still streaming), `ConversationModel.ungroupedEntries` (flat entries, used by search) /
    `entries` (grouped, displayed), `expandedToolGroups` (in memory, never persisted), `toggleToolGroup(_:)`,
    `reveal(entryId:)` (search expands the group of a match; `ChatView.pendingScrollId` scrolls when the cell
    appears). View: `App/Chat/ToolGroupRow.swift`.
  - Host screen: `ActiveSessions` (`ActiveSessions.swift`, pure: sessions from all of the host's projects that are
    waiting for an answer (`pendingCount > 0`) or whose turn is running (`phase.isBusy`); offline copies and
    unavailable lists ignored, no duplicates; waiting first, then most recent activity, then id for equal activity;
    at most five rows then « et N autres sessions en cours » ("and N other running sessions", `hiddenLabel`); states
    `loading` / `empty` / `entries`), `AppModel.activeSessions(for:)` (built from the cached `SessionsModel`s;
    `loading` while the host is not reached and has no live list, and during the first subscription of a list shown
    from its offline copy), `activeSessionsWatchKey(for:)` (key of `HostView`'s task: projects + "connected", to
    restart failed lists on every established connection), `watchActiveSessions(for:)` (waits for the connection then
    starts each project's model) / `refreshActiveSessions(for:)` (pull to refresh) — unstructured tasks on the main
    actor, awaited in order: the isolation checker rejects `withTaskGroup` here.
  - Diffs and workspace: `FileDiff` / `UnifiedDiff` / `LineDiff` (common diff: `git diff` patch, host hunks, bounded
    local diff for previews), `WorkspaceChangesModel` (a project's Git changes and actions, one at a time) and
    `FileBrowser` (per project, in `AppModel`), `ToolPreviews` (`PermissionPrompt.preview`, `ToolCall.fileDiff`),
    `ConversationModel.fileChanges(for:)` (retry on `proto.staleRevision`) and `retryLastResponse()` (`retryTurn`),
    `forkableRowIds` / `fork(rowId:)` (« Repartir d'ici », "Fork from here": `forkAssistant` CAS, child session opened by
    `ChatView`), `MarkdownBlocks` (headings, lists, quotes, tables, code).
  - Formulas: `MathText` (`$…$` rules of `message.tsx` ported as is, inline `$$…$$`, bubble pieces `messageParts`),
    `MathMarkdown` (formulas replaced by U+E000… markers, Markdown parsed once then split back), `MarkdownBlock.math`
    (`$$` blocks and ```` ```math ````).
  - Offline reading: `ConversationCache` (`OfflineCacheStorage`, `FileOfflineCacheStorage` /
    `InMemoryOfflineCacheStorage`; one JSON per entry + `manifest.json` in `Application Support/OfflineCache/`,
    protection `.completeFileProtectionUntilFirstUserAuthentication` (complete protection made a locked background
    write see the manifest as "missing"), excluded from backup; 20 conversations per host, 20 MB, eviction by
    `savedAt`; never a token), `ConversationSnapshot.offlineJSON(keepingLast:)` and
    `SessionsIndex.offlineJSON(excluding:)`, `OfflineLabels` (banner, size), `ConversationModel.offlineCopyDate` /
    `SessionsModel.offlineCopyDate` (copy shown on open, replaced on the first `.updated`; live state frozen by a
    disconnect is written immediately; never rewritten from a copy; sub-agent threads are not cached),
    `detachOfflineCache()` called by `AppModel` before `stop()` when archiving, deleting a session or deleting a host
    (address or token change: copy kept). On the `App/` side: `OfflineSaveTask` (`ZCodeApp.swift`, iOS background
    task with an expiration handler), banner in `ChatBanners.swift`, host screen. Identifiers: `offline-banner`,
    `offline-retry`, `host-offline-cache` (size and « Vider le cache hors ligne », "Clear offline cache", with
    confirmation; the « Hors ligne » ("Offline") section of `HostView` must stay after « Projets » ("Projects"),
    otherwise `testParcoursListeEtReglages` no longer finds `workspace-…` in the lazy list).
  - Times and durations: `TimeLabels` (pure formats, injected time zone and locale, 24 h, `Date.VerbatimFormatStyle`),
    `ChatEntry.messageTime` (question and last answer of each turn), `ToolCall.timing` / `ToolTiming` / `boundsLabel`,
    `SessionWorkTime` (sum of `activeMs`, running turn since `startedAt`, "≥" if history is partial) and
    `ConversationModel.workTime`, `SessionDurations`, `AppModel.sessionCreatedAt` (sessions index: the snapshot has no
    creation date).
  - Sub-agent threads: `SubagentLink` (Agent card ↔ `subagent` row by `parentToolCallId`, fallback for a single pair
    per turn, title `getAgentPrimaryText` without call title), `SubagentLabels`, `RunningSubagent` /
    `ConversationSnapshot.runningSubagents` (`ZCodeV4`), `ConversationModel.readOnly` (no catalogue, no settings, no
    haptics) and `AppModel.conversation(…, readOnly:)`. On the `App/` side: `App/Chat/SubagentViews.swift`
    (`SubagentOpenAction`, « Voir le fil » ("View thread"), chip and list of running sub-agents: the sheet is held by
    `ChatView` (`showingRunningSubagents`), not by the chip, which disappears with the last sub-agent; empty list:
    « Aucun sous-agent en cours » ("No running sub-agent")); `ChatView(subagent:)` read-only.
  - Adding a project: `ProjectPickerModel` (host folder browser: root = parent of the first project announced by
    `server-info` (there is no home field in `server-info`), fallback `/` if there is no project or the home is
    unreadable; folders only (`includeHidden: false`); navigation stack — « Remonter » ("Up") goes back to the
    previous folder, not to the computed parent (symbolic links); `Listing` `loading`/`loaded`/`failed` with an
    anti-race generation, like `FileBrowser`; « Choisir ce dossier » ("Choose this folder") = `HostStore.addWorkspace`,
    validation and de-duplication unchanged). On the `App/` side: `ProjectPickerView` (`.sheet` of `HostView`, no text
    field any more; bottom bar « Remonter » + path in `.safeAreaInset(edge: .bottom)` with a `.bar` background, **not** in
    `ToolbarItem(placement: .bottomBar)`: the iOS 26 toolbar filters text out of the accessibility tree, so the path
    became invisible to UI tests and VoiceOver).
  - Goals: `GoalCommand` (parses `/goal …` like the web: the objective is sent alone, `displayText` = typed text),
    `GoalSummary` (status, live duration, iterations, verifications), `ConversationModel` (`goal`, `startGoal`,
    `pauseGoal` / `resumeGoal` CAS, `canPauseGoal` / `canResumeGoal` read from `availability`).
  - Coding Plan usage: `UsageModel` (per host; account-based provider from `ModelCatalog` — `Provider.accountAccess`,
    `config.access` of type `zhipu-account` without secret — read on demand, no listening) and `UsageLabels` (windows,
    unavailability reasons, host errors); `UsageLabels.composerQuota` (two concentric rings at the top of the composer,
    `QuotaRings`: 5 h outside, week inside (only one without a weekly window), text = remaining for the 5 h window;
    orange < 20 %, red < 5 % (on the rounded value) per ring, hidden if the balance is hidden); quotas already read are
    re-read when returning to the foreground; types `UsageEntitlementSnapshot` / `UsageQuotaLimit` / `UsageWindow` in
    `ZCodeV4`.
  - Plan resets (same screen): status read with the quotas, then eligibility re-requested from the provider on every
    read (`requestCodingPlanResetOpportunity`: a refusal or a rate limit is not an error, a granted opportunity
    re-reads the status; without this call the status only shows opportunities already granted); consumption
    (`useReset`) one at a time, confirmed by the history of the type (re-reads spaced 0.3/0.8/1.6/3 s, injectable via
    `pause`), then history marked as read and gauges re-read; `resetIssue` without hiding the gauges, notice/error of
    the last action surviving re-reads; types `CodingPlanResetType` / `CodingPlanResetStatus` /
    `CodingPlanResetOpportunityResult` in `ZCodeV4`.
  - Extensions: `SubagentsModel` (per host and `ExtensionScope`, cached in `AppModel.subagents(for:scope:)` and cleared
    by `hostDidChange`; list read on demand without listening, kept offline read-only, re-read after each mutation),
    `SubagentSections` (custom / plugins / built-in, web rules), `ExtensionsLabels` (labels and errors, defined once)
    and `ModelChoice` (model + strongest effort in the catalogue), `SubagentForm` (creating and editing a sub-agent:
    web rules, unknown tools kept, advanced fields honoured by the runtime (disallowed tools, skills, max turns,
    background, permission mode in User scope only), MCP servers carried over as is, description unescaped because host
    3.15.1 escapes `"` and `\` on write without unescaping on read) and `SubagentsModel.save` (agent scope, old path
    sent, detail follows a rename).
  - Plugins: `PluginsModel` (`plugin-management` channel, per host and scope, cached in `AppModel.plugins(for:scope:)`
    and cleared by `hostDidChange`; `getPluginsOverview` and `listPlugins` read together on demand, no listening,
    overview kept offline read-only; `describe` once per plugin; `actionError`), `PluginCatalogLayout` (installed
    including orphans, built-ins to restore, catalogue by source — ZCode's official source first —, search ignoring
    case and diacritics, category filter) and the plugin labels of `ExtensionsLabels` (never an empty string displayed).
  - Plugin operations: `PluginsModel.{install, update, uninstall, restore, setEnabled, cancelOperation}` with
    `PluginOperation` (one at a time; installation carries an `operationId` cancellable through
    `cancelPluginOperation`, always for the user; `updatePlugin` always with `pluginId`; an `error` diagnostic in a
    success response is a failure; lost connection = unknown outcome, list re-read; re-read after each operation, its
    notice and error survive that re-read) and `ExtensionsLabels.installWarning` (warning before installation, text
    specific to the iPhone app: the host has none).
  - Plugin configuration: `PluginConfigForm` (one option per field, same rules as the web's `pluginConfigPatch.ts`:
    only modified fields are sent, « Effacer » ("Clear") = `clearOptionKeys`, a sensitive option is never pre-filled and
    empty = unchanged, decimal-comma numbers accepted, « Obligatoire. » / « Nombre attendu. » ("Required." / "Number
    expected.")) with `PluginConfigPatch`, `PluginsModel.{configure, resetConfig}` (in the model's scope, through the
    same `perform` method) and `PluginsModel.canStartOperation` (single "an action may start" rule).
  - Plugin sources: `PluginsModel.{sourceIssue, validateSource, addSource, removeSource, refreshSources}` (local check
    before any call: empty or relative path rejected; `dryRun` validation is not an operation and touches neither notice
    nor error; `addSource` and `refreshSources` carry a cancellable `operationId`; official sources cannot be removed;
    same `perform`, re-read and error diagnostics as the other operations) and
    `ExtensionsLabels.{sourceKind, sourceLabel, masked}` (credentials in an `https://user:token@host/…` address are
    masked before any display; a source's `headers` are never read).
- `App/` — thin SwiftUI views (UI currently in French):
  - `App/Chat/` (conversation, composer, queue, banners, approval and question dock; attachments: `AttachmentPicker`
    ("+" menu: attachments, favourites), `PromptFavoritesView` (favourites management), `AttachmentStrip` (thumbnails,
    progress, retry, removal) and `AttachmentImages` (images scaled down to 2000 px, JPEG 0.85 / PNG kept, 240 px
    thumbnail); `ImageViewer` (full screen: `UIScrollView` zoom, scrolling, sharing, swipe to dismiss)).
  - `App/Workspace/` (Changes with Git actions, `CommitSheet`, `BranchMenu`, Files, file reader),
    `App/Sessions/ArchivedSessionsView.swift` (archived conversations: unarchive, delete permanently) and
    `App/Chat/TimeViews.swift` (`MessageTimeLabel`, `SessionDurationsBar` below the bar, `ToolDurationLabel`; each with
    its own `TimelineView`, no shared clock).
  - `App/Support/FormulaRenderer.swift` (a single off-screen `WKWebView`, local KaTeX, serial queue, in-memory image
    cache bounded to 32 MB; capture decision A1: `takeSnapshot` without a window; render bounded to 5 s, page load to
    30 s; capture refused beyond 4,096 pt per side or 16,777,216 px), `FormulaPageLoader`, `MathViews.swift`
    (`FormulaStyle`, `MathInlineText`: a sentence = one `Text` composed by interpolation, since `Text + Text` is
    deprecated in iOS 26; `MathBlockView`; `MathMessageText` for the bubble).
  - `App/Support/DiffView.swift` (`lineFont`), `App/Chat/{GoalBanner,GoalSheet}.swift` (Goal banner, detail and sheet).
  - `App/Hosts/UsageView.swift` (Coding Plan usage: remaining gauge per window, resets — one row per type that has
    opportunities (number available, nearest expiry as relative text), « Réinitialiser » ("Reset") button with a
    confirmation dialog, progress and notice/error of the last action, subscription);
    `App/Hosts/ConnectionStatusButton.swift` (status dot in the host screen's bar, `.popover` bubble with state,
    « ZCode <version> », version warning, failure and « Réessayer » ("Retry")) and
    `App/Hosts/ActiveSessionsSection.swift` (« Sessions en cours » ("Running sessions") section, first on the host
    screen, hidden when the connection failed: an alert row replaces it); `HostView` bar with three icons (status, web
    interface, usage); `navigationDestination(for: SessionRoute.self)` is declared **only** in `HostView` (serves both a
    project's list and the host screen).
  - `App/Chat/UsageButton.swift` opens usage as a sheet from the conversation — icon only, grouped with the "⋯" menu,
    otherwise iOS 26 moves it into the bar's overflow; remaining 5 h quota read by VoiceOver.
  - All logic lives in `ZCodeAppCore`. Swift 6 strict concurrency.
  - Compact tool cards (like the Claude mobile app): dedicated fonts in `ZCodeTypography` (`toolCode`, `toolDiff`,
    `toolIcon`, `toolName`, `toolStatus`, `toolSummary`), `CodeBlock(style: .compact)` (tighter margins and header;
    `.regular` for answers, the dock and `UnsupportedCard`), diff and `DiffStatsLabel` in `ZCodeTypography.toolDiff`
    (`DiffView(lineFont:)`, `DiffStatsLabel(font:)`, default unchanged elsewhere); command, input and output collapsed
    to 12 lines, « Copier » ("Copy") takes the whole text.
- Accessibility identifiers (UI labels are French; the English meaning is given in parentheses):
  - Chat: `message-time` (tap: exact time), `session-durations`, `tool-duration`, `math-formula` (block formula;
    VoiceOver label = LaTeX source), `chat-list`, `chat-menu`, `chat-usage`, `chat-rename`, `rename-field`,
    `rename-submit`, `assistant-text`, `chat-search` ("⋯" menu), `chat-search-field`, `chat-search-counter` ("3/12" or
    « Aucun résultat », "No result"), `chat-search-previous`, `chat-search-next`, `chat-search-older`,
    `chat-search-close`, `code-copy` (« Copier » button of a code block; label « Copier le code » then « Copié »,
    "Copy code" / "Copied"), `tool-output-more`, `tool-input-more` (« Afficher les N lignes » ("Show N lines") then
    « Réduire » ("Collapse") for a tool card's output, or command, or input; VoiceOver labels « … de la sortie / de la
    commande / de l'entrée », « Réduire la sortie / la commande / l'entrée »), `message-copy`, `message-share`,
    `message-fork` (message context menu; « Repartir d'ici » only on an answer marked `canFork`), `image-viewer`,
    `image-viewer-close`, `image-viewer-share` (viewer for an attached image), `composer-field`, `composer-send`,
    `composer-stop`, `composer-attach`, `composer-attachment-<n>`, `composer-attachment-remove-<n>`,
    `user-attachment-<n>`, `composer-model`, `composer-effort`, `composer-mode`, `composer-quota`,
    `tool-group-<first rowId>` (tool-card group row, `ToolGroupRow`: value « replié » / « déplié », "collapsed" /
    "expanded"), `prompt-favorites` (« Gérer les favoris… », "Manage favourites…", in the "+" menu),
    `prompt-favorite-<n>` (favourite number n in the menu, from 0), `prompt-save-favorite`, `prompt-favorites-list`,
    `prompt-favorite-add`, `prompt-favorite-title`, `prompt-favorite-text`, `prompt-favorite-save`, `slash-panel`
    ("/" panel), `slash-row-<command|skill|subagent>-<name>` (row: command, skill or sub-agent), `slash-close`,
    `interaction-dock`, `interaction-option-<optionId>`, `interaction-choice-<value>`, `interaction-feedback`,
    `interaction-feedback-send`, `interaction-submit`, `interaction-decline`, `interaction-back`, `chat-retry`,
    `goal-banner`, `goal-status` (value = status), `goal-pause`, `goal-resume`, `goal-detail`, `composer-goal`,
    `goal-objective`, `goal-start`, `turn-changes-<rowId>`, `turn-changes-list`.
  - Lists: `workspace-<path>`, `sessions-list`, `session-unread`, `sessions-section-waiting`, `sessions-section-pinned`,
    `sessions-section-recent`, `session-pin-<sessionId>`; archiving: `sessions-archived`, `archived-sessions-list`,
    `archived-<sessionId>`, `archived-restore-<sessionId>`, `archived-delete-<sessionId>`.
  - Project: `workspace-changes`, `workspace-files`, `changes-list`, `change-<relative path>`, `files-list`,
    `file-entry-<name>`, `file-content`, `diff-view`, `git-branch`, `branch-<name>`, `branch-new`, `git-stage-<path>`,
    `git-unstage-<path>`, `git-discard-<path>`, `git-stage-all`, `git-commit`, `git-push`, `commit-message`,
    `commit-include-unstaged`, `commit-submit`, `commit-submit-push`, `git-action-error`, `git-notice`.
  - Adding a project (browser sheet): `project-picker` (sheet), `project-picker-list`, `project-entry-<name>`,
    `project-choose` (« Choisir ce dossier »), `project-up` (« Remonter »), `project-path` (current path, label = the
    path), `project-retry` (« Réessayer »).
  - Host screen: `connection-status` (status dot in the bar, value « Non connecté » / « Connexion » / « Connecté » /
    « Échec », "Not connected" / "Connecting" / "Connected" / "Failed"), `connection-detail` (bubble),
    `connection-retry`, `host-web` (web interface sheet, closed by « Fermer », "Close"), `host-active-sessions` (carried
    by the « Sessions en cours » header, not by the `Section`: query it with `descendants(matching: .any)`),
    `active-session-<sessionId>` (row), `host-connection-alert` (failure message, on the `Label`) and
    `host-connection-retry`.
  - Usage: `host-usage` (icon in the host screen's bar), `host-default-mode` (mode for new sessions), `usage-plan`,
    `usage-limit-<five-hours|weekly|tools|mcp|other>` (value = remaining share), `usage-account`, `usage-refresh`,
    `usage-error`, `usage-unavailable`, `usage-reset-<five-hours|weekly>` (value = number available),
    `usage-reset-action-<five-hours|weekly>` (button, opens the dialog), `usage-reset-confirm` (destructive button of the
    dialog; the system dialog's « Annuler » ("Cancel") is not exposed to XCUITest), `usage-reset-progress`,
    `usage-reset-notice`, `usage-reset-error`, `usage-reset-issue`.
  - Saved workflows: `workspace-workflows` (a project's bottom bar, only if the host opens the dynamic-workflows gate and
    not on an offline copy), `workflows-list` (Project / Global list), `workflow-row-<name>` (row; opens the launch
    sheet), `workflow-invalid-<index>` (file rejected by the host, greyed out, not tappable), `workflow-arg-<name>`
    (argument field: text, number, toggle or JSON), `workflow-launch` (« Lancer », "Launch", disabled while a field is
    invalid), `workflow-launch-error` (message and detail of a refused launch, sheet stays open), `workflow-run-card`
    (run card in the conversation, read as « Workflow <name>, <status>, <summary> »), `workflow-run-stop` (« Arrêter »,
    "Stop" the run, no confirmation), `workflow-run-agent-<siteId>@<ordinal>` (agent chip; opens its thread read-only if
    the host created one).
  - Sub-agent threads: `subagent-open` (« Voir le fil », under the Agent card), `running-subagents` (running sub-agents
    chip), `running-subagent-<childSessionId>` (list row).
  - Extensions: `host-extensions` (host entry, User scope), `workspace-extensions` (a project's bottom bar),
    `extensions-target` (target such as « <host> · Projet <name> », same VoiceOver value), `extensions-scope` (scope
    menu), `extensions-segment`, `subagents-list`, `subagent-row-<name>`, `subagent-enabled-<name>`, `subagents-error`,
    `subagents-notice`, `subagent-delete` (list and detail), `subagent-detail`, `subagent-model-override`,
    `subagent-effort-override`, `subagent-model-reset`, `subagent-new` (list bar), `subagent-edit` (detail),
    `subagent-editor` (sheet), `subagent-cancel`, `subagent-name`, `subagent-description`, `subagent-color`,
    `subagent-model`, `subagent-effort`, `subagent-all-tools`, `subagent-tool-<tool>`, `subagent-extra-tool`,
    `subagent-prompt`, `subagent-inject-agents-md`, `subagent-advanced` (collapsed section),
    `subagent-disallowed-tool-<tool>`, `subagent-skills`, `subagent-max-turns`, `subagent-background`,
    `subagent-permission-mode` (User scope only), `subagent-issues` (problems, once a field has been edited),
    `subagent-save`.
  - Plugins: `plugins-host-note`, `plugins-list`, `plugins-catalog` (link « Parcourir le catalogue (N) », "Browse the
    catalogue (N)"), `plugins-category` (catalogue menu), `plugin-row-<name@source>` (rows of the list and the
    catalogue), `plugins-catalog-list` (catalogue list), `plugin-detail`, `plugin-components`, `plugins-error`.
  - Plugin operations: `plugin-install` (then confirmation with the warning), `plugin-progress` (indicator and elapsed
    time), `plugin-cancel` (installation only), `plugin-enabled` (scope enable toggle), `plugin-update`,
    `plugin-uninstall` (then confirmation), `plugin-restore-<name@source>` (« À rétablir », "To restore", row and
    detail), `plugins-notice` (notice of the last action).
  - Plugin configuration: `plugin-configure` (detail, if the plugin declares options), `plugin-config-<key>` (option
    field: text field, secure field or toggle), `plugin-config-clear-<key>` (« Effacer » / « Annuler l'effacement »,
    "Clear" / "Undo clear", only if the value is defined in the screen's scope and the option is sensitive or the scope
    is a project: web rule, `PluginConfigForm.Field.canClear`), `plugin-config-save`, `plugin-config-reset` (then
    confirmation), `plugin-config-cancel` (the sheet's « Fermer »).
  - Plugin sources: `plugins-sources` (plugin list bar), `sources-list`, `source-row-<id>`, `source-remove-<id>` (swipe,
    non-official sources only, then confirmation), `sources-refresh`, `sources-add`, `source-field`, `source-validate`,
    `source-validation` (« Source valide », "Valid source", or the error), `source-submit`, `source-close` (« Fermer »
    of the add sheet); progress and cancellation of a source operation reuse `plugin-progress` and `plugin-cancel`.
  - Additional sub-agent form identifiers: `subagent-extra-disallowed-tool` (row of a disallowed tool outside the list,
    with « Retirer », "Remove") and `subagent-mcp-servers` (« N serveurs MCP » note: carried over as is, not editable).
- `host/` — installation and service of the ZCode web server on hosts.
- Extensions: marketplace plugins and native sub-agents, managed **on the host** (nothing runs on the iPhone).
  Per-layer overview; model and form details are above ("Extensions", "Plugins").
  Real fixtures: `Tests/Fixtures/v3.15.1/{subagents-read,subagents-lifecycle,plugins-read,plugins-lifecycle}/`.
  - `ZCodeV4`: `Subagents.swift` (`AgentSummary`, `SubAgentConfig`, `AgentsListResult`, `AgentDiagnostic`;
    `AgentScope`, `AgentSource`, `AgentColor`, `AgentPermissionMode` as `OpenEnum`), `PluginManagement.swift`
    (`PluginsOverview`, `PluginsList`, `AvailablePlugin`, `InstalledPlugin`, `PluginInfo`, `MarketplaceSummary`,
    `PluginDiagnostic`, `PluginInstallResult`…) and `ExtensionScope` (`.user` / `.workspace(path)`). Tolerant decoding:
    unknown field ignored, unknown enum value kept and shown raw. Hard-coded exceptions, because the host has no source
    for them in 3.15.1 (copied from ZCode Web): the 8 colours (`AgentColor`), the permission modes
    (`AgentPermissionMode`) and the 9 offered tools (`SubagentForm`).
  - `ZCodeClient`: `SubagentsClient` (`subagents` channel; `provider: "glm"`; client-side refusals
    `SubagentsClientError.readOnly` / `.notOverridable`, because the host does not enforce these guards) and
    `PluginManagementClient` (`plugin-management` channel). One call = a single object in an array; a field without a
    value is **omitted** (never `null`); `workspacePath` is always absolute on the host side. **Forbidden**: no
    `listen` on `subagents` (the channel has no events, and listening to a nonexistent event can bring the server
    down); never `disposeAll`, `prepareRuntimeState`, `readRuntimeConfig`, `getPrimaryUserAgentsDirectory`; no
    listening to `onDynamicPluginOperationProgress`; never the `plugins` channel (removed, it answers
    `supported:false`) nor `plugin-sync`.
  - `ZCodeAppCore`: `SubagentsModel`, `SubagentForm`, `SubagentSections`, `PluginsModel`, `PluginCatalogLayout`,
    `PluginConfigForm`, `ExtensionsLabels`, `ModelChoice` (and `ExtensionsHost`, internal: connection and project shared
    by both models). Models are cached by `(hostId, scope)` in `AppModel` and cleared by `hostDidChange`: nothing is
    shared between two hosts, even with identical project paths.
  - `App/Extensions/`: `ExtensionsView` (destination: host target · scope, Plugins / Sub-agents segments),
    `SubagentsListView`, `SubagentDetailView`, `SubagentEditorView`, `SubagentSupport`, `ModelEffortPicker`,
    `PluginsView`, `PluginCatalogView`, `PluginDetailView`, `PluginConfigView`, `MarketplaceSourcesView`. Entry points:
    `host-extensions` (host settings) and `workspace-extensions` (project).
  - When changes take effect (shown as is): plugins → new sessions only; sub-agents → next turn of each conversation
    (~1.5 s after saving). Client-side guards: edit or delete a sub-agent only if `source == "user"`, scope `user` or
    `workspace` and not `readOnly`; the sub-agent enable toggle exists only in User scope; list re-read after each
    mutation (the `enabled` returned by the host is not reliable); `installPlugin` always installs for the user;
    `updatePlugin` always with `pluginId`; a success response carrying an `error` diagnostic is a failure; a
    `sensitive` option is never read back nor persisted.
  - Probe on a Linux host (throw-away source created there, token through an environment variable, never printed),
    from `Packages/ZCodeKit`:
    `ssh <user>@<linux-host> 'mkdir -p <linux-workspace>/.zcode-check/extensions && sh -s <linux-workspace>/.zcode-check/marketplace' < Probe/make-plugin-marketplace.sh`,
    then
    `ZCODE_TOKEN="$(ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token')" swift run zcode-probe extensions --url https://my-linux-host.your-tailnet.ts.net --workspace <linux-workspace>/.zcode-check/extensions --marketplace <linux-workspace>/.zcode-check/marketplace`
    (without `--invoke`: invocation is proven on the macOS host); afterwards `rm -rf <linux-workspace>/.zcode-check` on
    the Linux host.
  - Checks: `swift test` (models, forms, tolerant decoding on fixtures); `zcode-probe extensions` (real contract, see
    "Commands"); `testParcoursSousAgent` (≈ 1 min) and `testParcoursPlugin` (≈ 1 min 15, real installation on the
    host), **no GLM prompt**, described under "Commands"; the latter requires
    `TEST_RUNNER_ZCODE_PLUGIN_SOURCE=$ZCODE_SEED_WORKSPACE/.zcode-check/marketplace` (skipped otherwise).
  - Re-reading and display: `loadIfNeeded` **silently** re-reads an already-read list on every appearance (operations
    affect the whole host, ZCode Web included) while keeping list, notice and error, never during an operation, in a
    task detached from `.task`; « Hors ligne » ("Offline") banner only if `isOffline` (connection failure), otherwise
    « Lecture impossible » ("Cannot read"); every raw host message goes through `ExtensionsLabels.masked` (address
    credentials and sensitive query parameters); `SubagentsModel.userScopeUnavailable` / `canCreate` (User scope not
    offered by the host).

## Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points to the CLT
(cd Packages/ZCodeKit && swift test)
xcodegen generate                                                 # the .xcodeproj is not versioned
xcodebuild build -project ZCode.xcodeproj -scheme ZCode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/DerivedData
```

Signing (before building for a device): copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig` (git-ignored), set `DEVELOPMENT_TEAM` and `ZCODE_BUNDLE_ID_PREFIX`, then run
`xcodegen generate`.

iOS tests (simulator) and real UI journeys against a host:

```sh
xcodebuild test -project ZCode.xcodeproj -scheme ZCode -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData -only-testing:ZCodeAppTests
TEST_RUNNER_ZCODE_SEED_URL=https://my-mac.your-tailnet.ts.net \
TEST_RUNNER_ZCODE_SEED_TOKEN="$(cat ~/.config/zcode-web/token)" \
TEST_RUNNER_ZCODE_SEED_WORKSPACE=/Users/me/projects \
TEST_RUNNER_ZCODE_SEED_SUBFOLDER=zcode-ios \
xcodebuild test … -only-testing:ZCodeUITests -resultBundlePath build/ui-tests.xcresult   # then delete the .xcresult
scripts/install-device.sh                                       # (re)install on the iPhone
host/update-zcode.sh v3.15.2                                   # verified upgrade: parallel build,
                                                                # check on a spare port, switch or roll back
host/update-zcode.sh v3.15.1 --rebuild --skip-check --keep 1   # same version rebuilt (staging fix) into
                                                                # versions/3.15.1+r<timestamp>, no GLM prompt
```

`host/installed-version.txt` records the ZCode version the client is tested against; `host/update-zcode.sh` bumps it.

### UI journeys

The UI journeys (`ZCodeUITests`) run against a **real host**, and some of them cost GLM prompts (noted below).
Seed variables (passed with the `TEST_RUNNER_` prefix):

- `TEST_RUNNER_ZCODE_SEED_URL`, `TEST_RUNNER_ZCODE_SEED_TOKEN` — host address and token.
- `TEST_RUNNER_ZCODE_SEED_WORKSPACE` — absolute path of a project the host serves (below: `$ZCODE_SEED_WORKSPACE`, "your
  test workspace"); its parent directory is treated as the host home by the project-picker test. Tests are skipped
  without it.
- `TEST_RUNNER_ZCODE_SEED_SUBFOLDER` — a sub-folder of that workspace containing a `README.md` (default `zcode-ios`,
  e.g. a clone of this repo); written `<subfolder>` below.
- `TEST_RUNNER_ZCODE_SEED2_URL` / `TEST_RUNNER_ZCODE_SEED2_TOKEN` / `TEST_RUNNER_ZCODE_SEED2_WORKSPACE` — second host,
  for `testParcoursDeuxHotes` only.

Some journeys write into the test workspace (`.zcode-check/`, `.zcode/`): use a workspace you do not mind the tests
touching, and clean up as described.

`testParcoursChatPong` creates a session, sends a GLM prompt, waits for "PONG" then deletes the session: it costs one
GLM prompt. `testParcoursFenetreSession` (one GLM prompt): host · folder subtitle, rename (bar then list), archiving.
`testParcoursApprobation` grants file-write permissions from the dock (one GLM prompt; leaves
`$ZCODE_SEED_WORKSPACE/.zcode-check/` on the host, to be deleted). `testParcoursFichiers` (**no** prompt): Files →
`<subfolder>/README.md`, then Changes (the workspace itself is not expected to be a Git repository).
`testParcoursListeEtReglages` (**no** prompt): default mode « Autonome » ("Autonomous") on the host, composer draft in
« Autonome » with quota, deletion, search. `testParcoursAjouterProjet` (**no** prompt): « Ajouter un projet » ("Add a
project") → browser sheet at the host home → descend into the workspace folder then `<subfolder>`, « Remonter » twice,
descend again, « Choisir ce dossier » → row added then removed. `testParcoursLectureConversation` (one GLM prompt): bash
code block → « Copier » pasted into the composer, context menu, search, archiving. `testParcoursImagePleinEcran` (**no**
prompt): image pasted into the composer → viewer → draft deleted (the system paste alert blocks the app's main thread:
`allowPasteIfAsked` queries SpringBoard first, otherwise the query on the app times out after several minutes).
`testParcoursGoal` (≈ 2 GLM calls): « Goal » button → trivial objective → « Atteint » ("Achieved") → detail → session
deleted. `testParcoursDeuxHotes` (**no** prompt): switch between two hosts (e.g. macOS host ↔ Linux host) — additionally
requires the `TEST_RUNNER_ZCODE_SEED2_*` variables (Linux host token via
`ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token'`).

The simulator must have « Connect Hardware Keyboard » disabled (`defaults write com.apple.iphonesimulator
ConnectHardwareKeyboard -bool false`, otherwise `typeText` fails). Bound an `xcodebuild test` with
`perl -e 'alarm 480; exec @ARGV' xcodebuild …` (no `timeout` on macOS).

`testParcoursPanneauSlash` (**no** prompt): "/" → panel (host command, Explore), filter, `/plan` alone → plan mode
without sending, skill token, « Fermer », draft deleted. `testParcoursRepartirDIci` (one GLM prompt): PONG → « Repartir
d'ici » → child session → both archived. `testParcoursHeuresEtDurees` (one GLM prompt per run): new session → forced
Bash command → `tool-duration` queryable (its label is the row's, ending with the duration), `message-time` relative →
exact → relative, `session-durations` « de travail » ("of work") → archiving.

`testParcoursFilSousAgent` (**no** prompt): project `$ZCODE_SEED_WORKSPACE` → session « Lister fichiers zcode_ios/host
via sous-agent Explore » → `subagent-open` → child thread read-only (neither `composer-field` nor `interaction-dock`, at
least one `assistant-text`) → back. This **support session** must exist on the host and stay there (do not archive or
delete it; the journey is replayable without a prompt). Create it once with `Probe/subagent-session.json` +
`Probe/send-text.json` (one GLM prompt, asking for a listing through the Explore sub-agent); its title must match the
literal title above, which the test code uses (rename it, or adapt the test).

`testParcoursGroupeOutils` (**no** prompt; ≈ 45 s): same support session as `testParcoursFilSousAgent`. Parent:
`tool-group-*` « replié » (reasoning + Agent card; the card and `subagent-open` stay visible), tapped ⇒ « déplié » (one
« Réflexion » ("Reasoning") visible) ⇒ « replié »; `composer-quota` present. Child thread (`subagent-open`): group « A
réfléchi, exécuté 2 commandes » (2 Bash + 3 reasoning items), `Bash, …` cards hidden when collapsed, visible when
expanded; then `chat-search` "maxdepth" (only in the 2nd command) ⇒ counter "1/1", group « déplié », the command's card
visible. Tool cards have no identifier: find them by label (`label BEGINSWITH 'Bash, '`); `descendants(.any)` also
counts their nested elements (do not count cards that way). These assertions depend on what the model did when the
support session was created.

`testParcoursWorkflowEnregistre` (**one GLM prompt per run**; ≈ 50 s): project `$ZCODE_SEED_WORKSPACE` →
`workspace-workflows` → `workflow-row-ios-ui` → `workflow-launch` (default of `who` kept) → `workflow-run-card`
« Terminé » ("Finished") without `workflow-run-stop` → answer of the turn that the end of the run **always** triggers
(`backgroundResult`), awaited until `composer-stop` disappears → session archived, back to `workflows-list`. Permanent
support file on the host: `<workspace>/.zcode/workflows/ios-ui.dwf.ts` (trivial workflow without an agent, argument `who`
with only a default; keep it; to create it: a `/* zcode-workflow` header with `description:` and
`args: who: { type: string, default: monde }`, body ``return `bonjour ${String(args.who)}`;``). Requires the host to
open the dynamic-workflows gate (`getDynamicWorkflowClientConfig().enabled`), otherwise the entry is missing and the
test fails. Each run leaves in `<workspace>/.zcode/` a draft `workflow-drafts/ios-ui.dwf.ts` and a
`workflow-runs/dwfrun-<uuid>.mjs` (with their `.gitignore`): delete only those files of the run
(`rm $ZCODE_SEED_WORKSPACE/.zcode/workflow-drafts/ios-ui.dwf.ts $ZCODE_SEED_WORKSPACE/.zcode/workflow-runs/dwfrun-<uuid>.mjs`,
`<uuid>` of the run), never the whole folders (the workspace may be a real project), then each `.gitignore` only if its
folder contains nothing else (`rmdir` afterwards), plus the log `~/.zcode/cli/rollout/model-io-<session>.jsonl` of the
triggered turn (the host keeps only 3).

`testParcoursSessionsEnCours` (**one GLM prompt**; ≈ 1 min; 3 model requests: turn, answer to the refusal, title): host
screen → status bubble (« ZCode <version> ») closed by a tap outside → web sheet opened then « Fermer » → `host-usage`
present → project `$ZCODE_SEED_WORKSPACE` → new session asking to write `.zcode-check/ui-en-cours.txt` → permission
dock → back to the host screen → `active-session-…` row **absent from the snapshot taken before creation** (snapshot
taken on a settled state: « Aucune session en cours » ("No running session"), or the same number of rows twice 1 s
apart) (your other running sessions are never touched; its label must contain « réponse attendue » ("answer expected"))
→ conversation opened from the host screen, which must mention `ui-en-cours.txt` before any refusal or archiving
(otherwise it fails without touching anything) → `interaction-option-deny` (the dock replaces the composer: no
`composer-stop` while waiting; the refusal tells the model to stop, it answers once) → end of turn (three consecutive
snapshots without dock or `composer-stop`) → archiving, back to the host screen. The session id is written to the test
output (`13J session : active-session-<id>`). Cleanup: `~/.zcode/cli/rollout/model-io-<session>.jsonl` and, if they
exist, `exec/<session>`, `exec/bash-startup/<session>`, `artifacts/<session>`;
`$ZCODE_SEED_WORKSPACE/.zcode-check/ui-en-cours.txt` is not written (request denied): `rm -f` it, then
`rmdir $ZCODE_SEED_WORKSPACE/.zcode-check 2>/dev/null` only if it exists. If an assertion fails after « Nouvelle
session » ("New session"), the journey's session **stays on the host** (draft, or pending request): recognise it by its
message « Crée le fichier .zcode-check/ui-en-cours.txt… » (id in the test output if it was read, otherwise
`~/.zcode/cli/log/zcode-<date>.jsonl`), archive it from the app or ZCode Web (deny a still-open request first), then
delete its `model-io-<session>.jsonl` log and the rest above; never touch another session.

`testParcoursSousAgent` (**no** prompt): project `$ZCODE_SEED_WORKSPACE` → Extensions → Sub-agents → project agent
`ios-ui-<5 digits>` created (first model of the catalogue), description edited, deleted; then User scope: Explore
(built-in) without toggle or « Modifier » ("Edit"). During the journey it writes into
`$ZCODE_SEED_WORKSPACE/.zcode/agents/` (the host then leaves the empty folder). `testParcoursPlugin` (**no** prompt):
host → Extensions → Plugins → throw-away source validated then added → `zcode-ios-probe` found in the catalogue,
installed (for the user, on the host), option `label` configured, disabled, uninstalled → source removed; additionally
requires `TEST_RUNNER_ZCODE_PLUGIN_SOURCE=$ZCODE_SEED_WORKSPACE/.zcode-check/marketplace`, a folder created before the
run by `Packages/ZCodeKit/Probe/make-plugin-marketplace.sh $ZCODE_SEED_WORKSPACE/.zcode-check/marketplace` (skipped
otherwise). Before the run, check that no leftovers of a previous attempt exist (`ls $ZCODE_SEED_WORKSPACE/.zcode/agents`,
`grep -l zcode-ios-probe ~/.zcode/cli/plugins/*.json`). Cleanup, after the run and after any failure along the way
(harmless if nothing exists):

```sh
rm -f $ZCODE_SEED_WORKSPACE/.zcode/agents/ios-ui-*.md
rmdir $ZCODE_SEED_WORKSPACE/.zcode/agents $ZCODE_SEED_WORKSPACE/.zcode 2>/dev/null
(cd Packages/ZCodeKit && ZCODE_PROBE_WORKSPACE=$ZCODE_SEED_WORKSPACE ZCODE_PROBE_USER_AGENTS=$HOME/.zcode/agents \
  swift run zcode-probe run Probe/extensions-cleanup.json)          # uninstalls the plugin, removes the source
rm -rf ~/.zcode/cli/plugins/{marketplaces,cache}/zcode-ios-probe-market $ZCODE_SEED_WORKSPACE/.zcode-check
```

Even after a successful journey, the host leaves these two copies of the source and adds `plugins.options: {}` to
`~/.zcode/cli/config.json` (remove it, or restore a copy taken before the run).

### Protocol probe

Protocol probe (macOS, against a real server):

```sh
cd Packages/ZCodeKit
swift run zcode-probe info                                   # server-info of the local host
swift run zcode-probe run Probe/handshake-sessions.json      # hello → initialize → sessions index
swift run zcode-probe run SCRIPT.json --url https://my-mac.your-tailnet.ts.net --record FOLDER
```

Token read from `~/.config/zcode-web/token` (or `ZCODE_TOKEN`); `${NAME}` in a script = environment variable. Run
`swift run zcode-probe` without arguments for the default `--url`, `--token-file` and `--workspace`; pass
`--workspace` explicitly to point at your test workspace.

Contract test (creates then deletes a real session; exit code 0 if everything passes):

```sh
swift run zcode-probe check --workspace $ZCODE_SEED_WORKSPACE   # local host
swift run zcode-probe check --url https://my-mac.your-tailnet.ts.net --workspace $ZCODE_SEED_WORKSPACE
```

Over the tailnet, the test file stays on the host: `rm -r <workspace>/.zcode-check` afterwards.

Real loop of a trivial Goal (≈ 2 GLM calls; pauses and deletes the session; code 0 if achieved):
`swift run zcode-probe goal [--record FOLDER]` (fixtures `Tests/Fixtures/v3.15.1/goal/`).

Real attachment (≤ 2 GLM calls; deletes the session; code 0 if conformant): `swift run zcode-probe attach [--record FOLDER]`
(fixtures `Tests/Fixtures/v3.15.1/attachments/`).

Fixtures for the `git` / `file` channels (no prompt, except the message generation of `git-actions`):
`Probe/make-fixture-repo.sh` then `Probe/git-files.json`, and `Probe/make-actions-repo.sh` then `Probe/git-actions.json`
(see `Tests/Fixtures/README.md`). Coding Plan quotas (no prompt): `Probe/usage-entitlement.json`. Plan resets (no
prompt, **no consumption** — never `/use` in the probe): `Probe/usage-reset.json` (status → opportunity → status;
fixtures `Tests/Fixtures/v3.15.1/usage-reset/`).

Sub-agent thread (**no** prompt): `swift run zcode-probe run Probe/subagent-thread.json` reads the parent (Agent card +
`subagent` row) then subscribes to the child; fixtures `Tests/Fixtures/v3.15.1/subagent-thread/`. The support session is
created once with `Probe/subagent-session.json` (`createSession`, `sessionId: null`) then `Probe/send-text.json` (one
GLM prompt). Leftovers on the host: `~/.zcode/cli/rollout/model-io-<session>.jsonl` (and the sub-agent's), and the
session's `agents/`, `exec/`, `artifacts/`.

Real contract of sub-agents and plugins (**no** prompt; with `--invoke`, on the macOS host only, ≈ 6 GLM calls: main
agent, sub-agent, title; code 0 if conformant): throw-away names created then removed, Explore model set then restored
to its read value, sensitive configuration written then cleared, refresh of all sources (network: the first one clones
`claude-plugins-official` into `~/.zcode/cli/plugins/marketplaces/`, ≈ 15 MB, which stays). `--workspace` is mandatory
and must be under a `.zcode-check` folder (code 2 otherwise):

```sh
mkdir -p $ZCODE_SEED_WORKSPACE/.zcode-check/extensions && Probe/make-plugin-marketplace.sh $ZCODE_SEED_WORKSPACE/.zcode-check/marketplace
swift run zcode-probe extensions --workspace $ZCODE_SEED_WORKSPACE/.zcode-check/extensions \
  --marketplace $ZCODE_SEED_WORKSPACE/.zcode-check/marketplace [--invoke] [--record FOLDER]
```

Afterwards, on each host: `rm -rf <workspace>/.zcode-check`, `~/.zcode/cli/plugins/{marketplaces,cache}/zcode-ios-probe-market`
(left by the host), `plugins.options: {}` added to `~/.zcode/cli/config.json` (or empty `config.json` and
`installed_plugins.json` created if they were missing), and with `--invoke` the logs
`~/.zcode/cli/rollout/model-io-<session>.jsonl` (session and sub-agent) and `~/.zcode/cli/agents/<session>/` of the
deleted session. The host keeps only 3 `model-io` logs: each `--invoke` evicts the user's oldest ones. After a failure:
`Probe/extensions-cleanup.json`. If the probe is interrupted (connection lost, Ctrl-C) between "override set" and
"previous value restored", Explore keeps the host's `preferredSelection` model: restore it by hand (ZCode Web,
Sub-agents → Explore, or `setBuiltInModelOverride`, without `modelSelection` if there was none) to the value of the
`explore.before` line of the output (or of the `--record` report).

Composer (throw-away project mandatory under `.zcode-check`):
`Probe/make-slash-workspace.sh $ZCODE_SEED_WORKSPACE/.zcode-check/composer`, then
`swift run zcode-probe run Probe/slash-read.json` (no prompt, `ZCODE_PROBE_WORKSPACE`) and
`swift run zcode-probe composer --workspace $ZCODE_SEED_WORKSPACE/.zcode-check/composer [--fork | --workflow] [--record FOLDER]`
(without an option no prompt; `--fork` one prompt; `--workflow` one prompt and a small cancelled run); afterwards
`rm -rf $ZCODE_SEED_WORKSPACE/.zcode-check/composer`. Fixtures `Tests/Fixtures/v3.15.1/{slash,fork,workflow-run}/`.

Saved workflows (throw-away project mandatory under `.zcode-check`; the `.dwf.ts` files are written there then deleted
by the probe, sessions deleted; code 0 if conformant):
`swift run zcode-probe workflows --workspace $ZCODE_SEED_WORKSPACE/.zcode-check/workflows [--with-agent [--cancel]] [--record FOLDER]`.
Cost: the end of each run triggers a model turn (stopped immediately by the probe, but the request has been sent);
without an option ≈ 1 GLM call; `--with-agent` (agent asking to write a file, request denied) ≈ 3;
`--with-agent --cancel` (run stopped while the request is pending) ≈ 2-3. Fixtures
`Tests/Fixtures/v3.15.1/saved-workflows/{trivial,agent,agent-cancel}/`.
Afterwards: `rm -rf $ZCODE_SEED_WORKSPACE/.zcode-check/workflows` (drafts `.zcode/workflow-drafts/` and
`.zcode/workflow-runs/*.mjs` included), then the logs `~/.zcode/cli/rollout/model-io-<session>.jsonl` (and
`model-io-sess_dwf-<runId>-actor_*.jsonl` with `--with-agent`) and `~/.zcode/cli/memories/projects/workflows-<hash>/`
left by the host. The host also leaves `~/.zcode/cli/memories/projects/composer-<hash>/` (created with the project's
first session) and, after a prompt, `~/.zcode/cli/rollout/model-io-<session>.jsonl`, `exec/<session>`,
`exec/bash-startup/<session>` and `artifacts/<session>`: delete them (same cleanup on a Linux host, through
`ssh <user>@<linux-host>`).

## ZCode protocol (source of truth)

ZCode sources built locally (e.g. a checkout in `~/src/ZCode`; installed tag: see `~/.local/share/zcode-web/current`).
Read them before touching the protocol:
- `packages/rpc/src/{protocol,serialization,channelClient,channels.shared,proxy-channel}.ts`
- `packages/shared/src/zcode-protocol-v4/*`, `docs/v4-refactor/10-protocol-spec.md`
- `packages/ui/src/v4/agentV4ConnectionHandshake.ts`, `packages/services/src/zcode-agent/zcodeAgent.ts`

Rules: **tolerant** decoding (unknown type → `.unknown`, never a crash); nothing hard-coded that can come from the
server (models, effort levels, modes, slash commands, approval options).

## Established facts (do not re-learn)

Observed on ZCode v3.15.1; re-check against the sources after an upgrade.

- **Protocol**: binary `/ws`; 13-byte frames → tag/VQL serializer → RPC (channels 100–103 / 200–204) → V4.
  Method call = **array** of arguments; event `onDynamicXxx(arg)` = raw argument. The `subscribe…` ack and the initial
  frame arrive in any order (`TopicStore` holds frames until the ack). Deltas typed by `op` (`row.appended`,
  `row.upserted`, `row.delta` with `path: "text"`, `state.updated`); a short answer may have no `row.delta`.
  `toolCall`: `inputStreaming → running → success`. Deliberate deviations: unknown rows and ops tolerated,
  `row.appended` for an existing `rowId` = replacement.
- **Sessions**: a session created without a first message appears in `sessions-index` only at its first `sendText`
  (phase `draft`) — the app shows it as a local draft; deletion publishes `session.removed`. The snapshot carries only
  the last 60 rows, the rest comes in pages (`rowsRange`). Reconnection: 0, 1, 2, 5, 10, 30 s, never after a refused
  token or an unknown protocol; keepalive ping 20 s / timeout 10 s.
- **Sending**: `sendText` is sent **without** `requestedDelivery` (the host chooses `startNow` / `queue` / `guide`);
  model, effort and mode accompany every send, `reasoningLevel` mandatory (Mistral: `"none"`). Send cut off or
  unreadable response: envelope kept, same `commandId`, reconciliation through `queryCommands`, at most 3 passes without
  outcome (delays 2 s then 5 s), then the text is returned to the composer. **Deliberate deviation from ZCode §9.3**
  (which would wait indefinitely): on mobile, the "being verified" banner must end. Modes hard-coded (`build`,
  `guarded`, `plan`, `yolo`) like the web: `workspace-config` is empty without an active session.
- **Approvals**: permission answer `{optionId}` (+ `freeText` ≤ 4,096 characters with `deny` / `workflowRefine`);
  questions and plan `{action: "accept", content}` (`answers` keyed by the question text, multiple choices joined by
  ", "); approved plan = `"approve"`, refusal = `{action: "decline"}`, plan text in `input.plan`.
  `accepted` / `duplicate` / `noop` (`proto.alreadyResolved`) = success; an answer is **never** re-sent on its own.
  `snoozeInteractionAutoResolution` once per request on the first touch.
- **Git and files**: `git` and `file` channels take a single object argument, with no project boundary on the host
  side. `git.refresh` outside a repository → `isRepository == false`. `readTextFile` ≤ 256 KiB (may end with U+FFFD),
  `readBinaryPreview` ≤ 25 MiB; WebSocket `maximumMessageSize` at 64 MiB. Diff of a turn: `conversationFileChangesV4`
  on the turn header (`{rowId, entityId}`), exact revision (`proto.staleRevision` during a turn: 3 attempts). No
  permission carries a diff: the app computes it. `discardPaths` with `staged: true` **erases** a staged addition: the
  app does not offer it. `generateCommitMessage` always with `locale: "en-US"` (otherwise Chinese is possible). No
  pull / fetch in ZCode.
- **Goals**: `sendGoalCommand` without CAS, ack `accepted` **without `result`** (see the snapshot); the host replaces an
  existing Goal and refuses in plan mode. Verification **by the model** (≥ 2 calls per iteration); a verifier error
  validates the Goal. No clearing and no budget in V4.
- **Attachments**: `attachmentBeginV4` → `attachmentChunkV4` → `attachmentCommitV4` (returns
  `ref = zcode-artifact://<sessionId>/tool-result-<uuid>`) then `sendText.attachments`. `text: ""` + attachment is
  accepted. `supportsImage` is read from `model-selection.getView` →
  `providers[].models[].config.properties.inputFormat`.
- **Coding Plan usage**: `usage-stats.getEntitlementSnapshot` requires `accountAccess` (`zhipu-account`, read from
  `providers[].config.access`, without secret), otherwise `not_configured`. In `quota.limits[]`, `usage` = cap,
  `currentValue` = consumed, `percentage` = **consumed** share (the web inverts it). Windows: credits `unit` 3 /
  `number` 5 = rolling 5 h, `unit` 6 = week; `TIME_LIMIT` = tool calls of the month; `mcpQuota.aggregate` = MCP of the
  day. No event: read on demand.
- **Built-in skills**: the `bundled-skills` pack (skill `dynamic-workflows`, required by `/workflow`) must sit next to
  `zcode.cjs`; the official staging does not copy it (`host/stage-zcode.mjs` does). The protocol catalogue excludes
  built-in skills: check with `node <runtime>/agent/zcode.cjs skills inspect dynamic-workflows`.
- **Mistral**: key in `~/.config/zcode-web/mistral-api-key` (600). The `provider-settings` view **returns the key in
  clear**: never log or record its output without masking (fixtures included).
- **Host and builds**: `pnpm build:zcode` breaks in v3.15.1 → custom packaging `host/stage-zcode.mjs`. Node 24 by
  absolute path (the `node` on the PATH may be older). A ZCode session's environment leaks into builds (`ZCODE_*`
  variables): the install scripts `unset` them. `update-zcode.sh` checks the new version on a spare server
  127.0.0.1:3031–3039 before switching.
- **Linux host (SteamOS)**: GitHub over HTTP/2 breaks cloning → `git -c http.version=HTTP/1.1`; a `nohup … &` in a
  one-line ssh command dies with the session → `systemd-run --user`. `~/.zcode` may be shared with a desktop ZCode.
- **Apple**: with a free account, reinstall every 7 days and no APNs. If `xcode-select` points to the CLT →
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Development pitfalls

- `swift test` only relays a test's output at the end: bound it with `perl -e 'alarm 60; exec @ARGV' swift test …`
  and trace into a file; `xcodebuild test` with `perl -e 'alarm 480; exec @ARGV' xcodebuild …`.
- After an Xcode update: `sudo xcodebuild -runFirstLaunch` before any simulator work (otherwise CoreSimulator is
  "out of date").
- macOS tests: `Host` is ambiguous with `Foundation.Host` → `ZCodeAppCore.Host`. A `#require` nested in another
  `#require` does not compile; a `Task {}` created in an actor inherits its isolation.
- SwiftUI: a container carrying an accessibility identifier must be `.accessibilityElement(children: .contain)`,
  otherwise it overrides its children's. On iOS 26, the toolbar filters text out of the accessibility tree
  (`ToolbarItem(placement: .bottomBar)` → prefer `.safeAreaInset`).
- UI tests: DEBUG seeding through `ZCODE_RESET=1`, `ZCODE_SEED_{NAME,URL,TOKEN}` (and `ZCODE_SEED2_*`); the token goes
  through `TEST_RUNNER_ZCODE_SEED_TOKEN`, never as an argument. The `.xcresult` may contain the environment: delete it
  after use.

## Conventions

- Code comments and UI strings are currently in French; identifiers are in English; documentation is in English. A
  localization plan lives in `docs/localization-plan.md`.
- Icon: vector source `design/zcode-app-icon.svg`; the app embeds `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
  (opaque 1024 × 1024 PNG, no rounded corners): to change it, export the SVG to that format and replace the PNG.
- No external dependency without a strong reason. Exception: KaTeX 0.16.45 (the version used by ZCode Web 3.15.1, MIT
  licence included) vendored in `App/Resources/KaTeX/` (folder reference in `project.yml`), so formulas render exactly
  like on the web; never loaded from the network.
- TDD: tests first for ZCodeKit (vectors ported from the TS tests in `packages/rpc/test`, fixtures recorded with
  `zcode-probe`).

## Security

A host's token gives **shell access** to that host: iOS Keychain only (service `zcode-ios.host-token`), never in logs,
the repository or fixtures; `wss://` through `tailscale serve` only (never `funnel`, never `--host 0.0.0.0`).

## macOS host

- Service: LaunchAgent `local.zcode-web` (`host/macos/install-service.sh`), logs `~/Library/Logs/zcode-web.log`.
- Token: `~/.config/zcode-web/token` (600). Runtime: `~/.local/share/zcode-web/current` (with the built-in skills pack
  `agent/packages/bundled-skills`, copied by `host/stage-zcode.mjs`; without it `/workflow` lacks its
  `dynamic-workflows` skill). Agent logs: `~/.zcode/cli/log/zcode-<date>.jsonl`.
- Tailnet URL: `https://<machine>.<tailnet>.ts.net` (e.g. `https://my-mac.your-tailnet.ts.net`).

## Linux host

- Example: SteamOS (immutable root, no sudo, no compiler); access via Tailscale SSH `ssh <user>@<linux-host>` (remote
  bash shell). Full installation and troubleshooting: `host/linux/README.md`.
- Service: systemd `--user` unit `zcode-web` (`host/linux/install-service.sh`, `Linger=yes`); runtime
  `~/.local/share/zcode-web/current` (built on the host, distrobox fallback for node-pty / cpu-features); logs
  `~/.local/state/zcode-web/zcode-web.log`.
- Token: `~/.config/zcode-web/token` — `ZCODE_TOKEN="$(ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token')"`
  (quotes required, otherwise `~` is expanded locally). Tailnet URL: `https://<machine>.<tailnet>.ts.net` (e.g.
  `https://my-linux-host.your-tailnet.ts.net`).
- If the host already serves other routes through Tailscale, use `tailscale serve --set-path` so existing routes are
  preserved; never `tailscale serve reset`, never `funnel`. Real contract:
  `… zcode-probe check --url https://my-linux-host.your-tailnet.ts.net --workspace <linux-workspace>`.
