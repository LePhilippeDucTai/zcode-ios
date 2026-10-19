# ZCode protocol fixtures

Recorded with `zcode-probe run … --record` against a real ZCode **v3.15.1** server (local macOS host).
Each file is one output line of the probe: `{"kind","name","seq","step","value"}`, where `value` is the JSON value
received (call result, event or error).

Anonymisation: absolute paths in the fixtures were rewritten to `/Users/me/…`, and the names of personal projects to
`project-a` … `project-h`.

- `handshake-sessions/`: `helloConversationV4`, `initializeConversationV4`, initial frame of the sessions index,
  ack of `subscribeSessionsIndexV4`, `model-selection.getView` view.
- `conversation/`: initial snapshot of an existing conversation and a `conversationRowsRangeV4` page (limit 200).
- `send-text/`: `sendText` command ("list the files…"), its `CommandAck`, then the turn's deltas:
  `row.appended` / `row.upserted` (reasoning, Bash `toolCall` `inputStreaming → running → success`, assistantText),
  `state.updated` (phase `running → completedSuccess`). Short answer: no `row.delta`.
- `send-text-long/`: same command with a long answer without tools → streaming `row.delta` (`path: "text"`).
- `git-files/`: `git` and `file` channels against the throw-away repository of `Probe/make-fixture-repo.sh` (no prompt):
  `git.refresh` (repository: staged rename and modification, modification, binary, untracked; then a folder outside any
  repository), `git.getDiff` (`git diff` patch, synthetic patch for an untracked file without `diff --git`, binary,
  staged, staged rename seen as a new file), `file.readdir` (without then with hidden files, missing folder → `ENOENT`),
  `file.readTextFile` (small, truncated at 256 KiB ending with U+FFFD, binary, folder → "Path is not a file"),
  `file.searchWorkspaceFiles`. Cleaned at recording time: `stack` removed (paths of the host runtime), truncated content
  reduced to its last 120 characters (`bytesRead` stays the host's value).
- `subagent-thread/`: real session with a sub-agent: parent (Agent card + `subagent` row) then subscription to the child
  (`Probe/subagent-thread.json`: recording needs no prompt, but the session was created beforehand with one GLM prompt
  through `Probe/subagent-session.json` + `Probe/send-text.json`).
- `goal/`: real loop of a trivial Goal (`zcode-probe goal`, one work call and one GLM verification): ack of
  `sendGoalCommand` (`accepted`, **without `result`**), successive states of `snapshot.goal` (`null` → `active`
  iteration 0 → `active` with a generated `summaryTitle` → `verifying` iteration 1 → `verified` with a `pass`
  verification), `goalVerify` marker (`running` then `pass` with `detail` = reason, updated in place), `goalStatus` of the
  index. Written by `ProbeOutput` (secrets masked); no personal path.
- `attachments/`: real attachment (`zcode-probe attach --record Tests/Fixtures/v3.15.1/attachments`, at most **two** GLM
  prompts; the session is deleted). Test image: 64 × 64 PNG, plain crimson #DC143C, 137 bytes, embedded in the probe (no
  real photo). Records: the conversation `config` (without `supportsImage`), reference returned by
  `attachmentCommitV4`, ack of `sendText` with `text: ""` (`accepted`, without reason), the model's answer to that
  message, `userInput` row carrying `attachments`, bytes read back by `attachmentReadV4`, GLM's answer about the colour.
- `git-actions/`: mutations of the `git` channel against the throw-away repository of `Probe/make-actions-repo.sh` (local
  bare remote): stage / unstage, discard a tracked file then an untracked one (**error** `pathspec … did not match`: the
  host never deletes), empty message refused, branch switch blocked (`tracked-changes-would-be-overwritten`, `paths`
  relative to the repository), missing branch, invalid name, commit of the index then of the working content, status,
  local branches (most recently committed first), first push (`setUpstream`) then a second one, branch creation, message
  generation (`generateCommitMessage`, **one call to the current model**: GLM-5.3). Cleaned: `stack` removed.
- `usage-entitlement/`: `usage-stats` channel, `getEntitlementSnapshot` (`Probe/usage-entitlement.json`, no prompt) for
  `account:zai-individual-coding-plan` with its `accountAccess` (`zhipu-account` read from `model-selection`): plan name,
  two `CREDIT_LIMIT` limits (5 h window: `unit` 3 / `number` 5; week: `unit` 6) where `usage` is the **cap**,
  `currentValue` the consumed amount and `percentage` the consumed share, quota of the official MCP (`mcpQuota`),
  subscription (`identityMasked` already `null` on the host); then the same request **without** `accountAccess` →
  `unavailableReason: "not_configured"`, everything `null`.
- Extensions (no prompt), recorded on the macOS host then replayed without recording on a Linux host (same shapes).
  Variables: `ZCODE_PROBE_WORKSPACE` (throw-away project, e.g. `<workspace>/.zcode-check/extensions`, outside the
  projects announced by `server-info`), `ZCODE_PROBE_MARKETPLACE` (folder from `Probe/make-plugin-marketplace.sh`, e.g.
  `<workspace>/.zcode-check/marketplace`) and `ZCODE_PROBE_USER_AGENTS` (`<home>/.zcode/agents`, checked against
  `agent.path` of `subagents-lifecycle/008`). Each folder is emptied (`rm -rf`) before a `--record`; before any replay
  and after a failure, run `Probe/extensions-cleanup.json` (same variables, harmless if nothing exists). Cleaned: `stack`
  removed from errors (`value.stack` and `value.data.stack`).
  - `subagents-read/`: `subagents.list` in `settingsUserOnly` then `allRuntimeScopes` (built-ins `general-purpose` and
    `Explore` as `readOnly`, agents of the official plugins in `pluginAgents`, `agent_ambiguous_name` diagnostics),
    unknown method → `Method not found: methodeInexistante`.
  - `plugins-read/`: `getPluginsOverview` in `user` then `workspace` scope, `listPlugins` `user` (the host's real
    inventory: official plugins and `github`), `describePlugin` of `github@zcode-plugins-official`, unknown method.
  - `subagents-lifecycle/`: project agent `zcode-ios-probe-agent` created, `already exists` refusal, length and reserved
    name (`Explore`), renamed to `zcode-ios-probe-agent-v2` with `oldFilePath`; user agent `zcode-ios-probe-user`
    created, disabled (`enabled: false` on re-read), deleted; clean final lists. `setEnabled` and `deleteAgent` return
    `null`. **Quotes**: the description sent, `Description avec "guillemets" et \ barre`, comes back as
    `Description avec \"guillemets\" et \\ barre` (006 and 007): the host escapes on write but does not unescape on
    read, and each new save adds more `\`.
  - `plugins-lifecycle/`: local marketplace `zcode-ios-probe-market` added (`dryRun` → `id: "dry-run"`, then for real),
    plugin `zcode-ios-probe` described, installed (`scope: "user"`), configured (`label` = `essai` in
    `configuredOptions`, sensitive `codeFactice` only in `optionSources`), disabled in the project
    (`enabledSource: "workspace"`; Project view disabled, User view enabled), configuration reset in both scopes, source
    refreshed, plugin updated (`pluginId`), installation of a missing plugin (**success** with a
    `plugin_dependency_missing` diagnostic, `severity: "error"`), unknown cancellation (`cancelled: false`), plugin
    uninstalled, source removed, refresh of the removed source → error -32603 `Marketplace not found: …`.
  - Secrets: no token (two `grep`s), no dummy value. The `configuredOptions` / `optionSources` of `plugins-read/003` and
    `plugins-lifecycle/006` and `008` were reviewed by hand: only those of the throw-away plugin are filled in, no secret
    of another plugin. The `/Users/me/…` paths remain (host paths, useful to the tests).
  - Host cleanup: the host leaves `plugins/marketplaces/zcode-ios-probe-market/`, `plugins/cache/zcode-ios-probe-market/`
    and `plugins.options: {}` in `~/.zcode/cli/config.json` (and creates `config.json` / `installed_plugins.json` if
    they were missing): delete or restore by hand. `~/.zcode/v2/agents-state.json` is created if it was missing (empty
    lists, kept); an empty `~/.zcode/agents` is deleted.
  - No folder for `zcode-probe extensions` (end-to-end contract of both channels): `--record FOLDER` writes a per-step
    report there (ids, states, keys of `configuredOptions` and `optionSources`, Explore override), never the raw
    responses, which carry the prompts of the host's real agents. The raw shapes are those of the four folders above.
- Composer, recorded on the macOS host in the throw-away project of `Probe/make-slash-workspace.sh`
  (`<workspace>/.zcode-check/composer`, two project skills including `review-agent`, which has the same name as a
  user-level skill on the host), deleted afterwards; `slash/` replayed without recording on a Linux host (same shapes).
  Cleaned: `stack` removed.
  - `slash/` (`Probe/slash-read.json`, `ZCODE_PROBE_WORKSPACE`, **no prompt**, no session): `001` hello, `002`
    initialize, `003` dynamic-workflows gate (`enabled: true`, `alwaysOn`), `004` project commands through
    `zcode-session.readWorkspacePresentation` and `005` the same through `zcode-agent` (identical: `goal`, `workflow`,
    `compact`, `init`, `plan`, custom `ios-dev`), `006` project skills catalogue without a session
    (`authority: "workspace"`, 36 skills, `review-agent` duplicated, absolute `path` to `SKILL.md`), `007` catalogue of a
    nonexistent session → error `-32004 Session is not active`, `008` `subagents.list` (`allRuntimeScopes`, raw
    recording: it deliberately contains the full `systemPrompt`s of the host's official plugin agents, `visual-judge`,
    without secrets; those of the built-in agents are empty), `009` unknown `zcode-session` method → `Method not found`.
  - `fork/` (`zcode-probe composer --fork`, **one GLM prompt** "PONG", sessions deleted): `001` ack of `createSession`,
    `002` catalogue of the empty session (`authority: "session"`, same skills as `slash/006`), `003` commands after
    creation, `004` ack of `sendText`, `005` answer with `actions.canFork`, `006` catalogue after the turn, `forkAssistant`
    refusals: `007` stale base (`stale`, `proto.staleRevision`), `008` user message as target (`rejected`,
    `guard.actionUnavailable`); `009` fork accepted (`result.sessionId`), `010` state of the child session (config,
    title "Fork of …", `totalCount` 5), `011` its first 4 rows (copied history; the `forkNotice` row, 5th, is not there).
  - `workflow-run/` (`zcode-probe composer --workflow`, **one GLM prompt**): **partial**, `001` to `003` as in `fork/`,
    then `004` ack of `/workflow`. No run: the session had the workflow tools, but the host refused `CreateWorkflow`
    for lack of the built-in `dynamic-workflows` skill (`bundled-skills` package missing from the installation; see
    "Built-in skills" in `CLAUDE.md`). To be re-recorded once the host is fixed.
- Saved workflows, `saved-workflows/`, recorded on the macOS host by `zcode-probe workflows` in
  `<workspace>/.zcode-check/workflows` (deleted afterwards); read them with `Fixtures.records(in:)` and the `name` field,
  never by number. Three folders: `trivial/` (no agent), `agent/` (`--with-agent`: request denied) and `agent-cancel/`
  (`--with-agent --cancel`: "Stop" while waiting). Each launch costs at least one model call (end-of-run turn, stopped
  by the probe).
  Names common to all three:
  - `workflow.config`: raw `coding-plan-subscription.getDynamicWorkflowClientConfig`.
  - `list.project` / `list.global`: `zcode-agent.listSavedWorkflows` `{workspacePath}` (one valid with `args`, one
    invalid) and `{scope: "global"}` (empty).
  - `createSession.ack`: ack of the session created without configuration; `state.initial`: its state (without `rows`,
    `config.mode: "build"`, no `workflowRuns`).
  - `start.notFound.ack` / `start.invalidArgs.ack`: refusals (`status: "failed"`, `reasonCode`, `message`).
  - `start.trivial.ack`: launch accepted (`result.runId`, `result.toolCallId`).
  - `state.trivial.<n>`: `{backgroundWorks, workflowRuns, control, pendingInteractions, launchRows}` at each change
    (`launchRows` = rows carrying the `toolCallId`: `turnHeader` and `userInput` with `origin: "workflowLaunch"`).
  - `state.trivial.final` (state without `rows`) and `rows.trivial.final` (row window) once the run is `completed`.
  - `state.trivial.afterResult`: state when the end-of-run turn (`origin: "backgroundResult"`) has started; `stop`: ack
    of its stop (a second `stop`, during cleanup, ends as `noop`).
  - `cancel.finished.ack`: `cancelBackgroundWork` on the finished run (`failed`,
    `backgroundWorkCancelRejected.not_running`).
  - `index.trivial`: raw summary of the session in the index (`workflowActivity: {runs: [...]}`).
  - `deltas.unknown`: `{unknownOps (empty), opCounts, stateUpdatedKeys}` over the whole probe.
  Additionally in `agent/` and `agent-cancel/` (second session, workflow `ios-probe-agent`):
  - `createSession.agent.ack`, `start.agent.ack`.
  - `state.agent.permission`: run view + raw `interaction` (origin `subagent`, `Write`), `optionKinds`, `origin`.
  - `state.agent.afterResubscribe`: view re-read through a new connection (the request is still there).
  - `agent/` only: `resolve.deny.ack` (refusal accepted); `state.agent.extraPermission` and `resolve.extraDeny.ack`
    (same request still seen for a moment then refused a second time, ack `accepted`: an unintended retry by the
    probe, fixed since); `state.agent.afterDeny` (run `completed`, end-of-run turn started).
  - `agent-cancel/` only: `cancel.running.ack` (`accepted`; run `stopped`, `stopReason: "user"`, request removed).
  - `state.agent.final`, `rows.agent.final`, `state.agent.afterResult`, `stop`, `index.agent`.

Observations: deltas carry their type in `op`; the `subscribe…` ack precedes the initial frame; no `fragment` frame was
observed (reassembly must be tested with synthetic data).

Send script: `SESSION_ID=… COMMAND_ID=$(uuidgen | tr A-Z a-z) NOW=$(($(date +%s)*1000)) PROMPT="…"
swift run zcode-probe run Probe/send-text.json --record FOLDER`.

Re-record on every ZCode upgrade (see `host/update-zcode.sh`).
Never leave a token in them (check: `grep -rlF "$(cat ~/.config/zcode-web/token)" Tests/Fixtures`).

## `synthetic/`

No `fragment` frame has been observed for real (frames fit under 1 MiB). `fragments-v3.json` was produced by ZCode
v3.15.1's own TypeScript encoder (`encodeTopicWireFrames`, `maxPhysicalFrameBytes: 420`, `deliveryKind: "recovery"`,
ordinal 9): a 241-byte `deltas` frame (CRC32 `081c9935`, accented text and emoji) split into 3 fragments. It is the
positive reference for reassembly; the error cases are built in the tests.

`model-selection-mistral.json` is hand-written after the structure of `model-selection.getView` in v3.15.1: it covers a
Mistral provider (effort level `none`, disabled model, missing context window), a provider without an id (ignored) and a
**dummy** API key (`cle-factice-ne-pas-conserver`) that must not end up in any decoded value.

`interactions-v3.15.1.json` is hand-written after ZCode v3.15.1's projection
(`apps/zcode-cli/packages/bootstrap/src/zcode-protocol-v4/product-projection.ts`, l. 3337–3480): no real request was
recorded. It covers a Bash permission (detail, `fullAccessOption` to be ignored), an AskUserQuestion with two questions
(single then multiple choice, visible countdown), an ExitPlanMode plan approval (`input.plan`), a sensitive input
without questions, a permission relayed from a sub-agent (option of unknown kind, "Refine") and a hook review (not
supported). The real shape of a permission is checked by `zcode-probe check`.
