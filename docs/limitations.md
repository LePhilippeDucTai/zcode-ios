# Known limitations

What the app does not do, either deliberately or because ZCode (v3.15.1) does not support it, plus the technical debt
noted during reviews. None of this prevents daily use.

## Missing from ZCode or not planned

- **Git**: no pull / fetch (missing from ZCode); no deletion of an untracked file; no reverting a turn's files
  (`applyFileRewind`) nor "edit and resend" (`editUserQuery`) — not planned.
- **Goals**: neither clearing nor budget (missing from the V4 protocol); Goal status not shown in the sessions list.
- **Files**: reading beyond 256 KiB is not paginated; images and binaries are not shown in the file browser; no file
  watching (refresh by hand); the old path of a rename is lost by the host.
- **Approvals**: the "Full access" option is not offered; hook review is left to the web interface; answer drafts
  (questions, instructions) are lost when the screen closes.
- **Queue**: editing and reordering queued messages is not exposed.
- **Notifications**: no APNs (free Apple account); haptics only while the app is open.
- **Coding Plan**: Start Plan limits (`getStartPlanSnapshot`, balances by `bucketId`) untested for lack of an account.

## Behaviours to know about

- Sends cut off by the network: the list of unconfirmed sends lives in memory (app killed → never verified); an
  unconfirmed send has no "pending" bubble; re-sent after a send accepted in the meantime, it arrives after it.
- An answer to a request stays hidden locally while the subscription lives if the host does not remove it.
- Committing at project level takes all files of the repository (the web filters on the current session); a generated
  commit message consumes a model call even if the Git identity is missing afterwards.
- "Retry" on an answer is not disabled while sending (a double tap shows a refusal).
- Changing a host's address without re-entering the token sends the old token to the new host.
- Markdown: no tables without a leading `|`, no `\|`, no indented code, no setext headings; simplified fences.

## Technical debt

- Connection: `reconnectWithBackoff` gives up after one series (~48 s) instead of staying at the 30 s step while the
  screen is visible; stale "Connected" state after a loss detected by the keepalive as long as no list calls
  `ensureConnected`; `isAlive` does not detect a half-open socket when returning to the foreground.
- `TopicFeed`: a frame without `fromSeq` → silent resync loop (to be bounded); `failure` never reset after a recovery;
  `mergeOlderRows` does not check `atSeq`.
- Keychain: `setToken` deletes then adds instead of `SecItemUpdate`; orphaned tokens after uninstalling.
- Performance: snapshot state accessors re-decoded on every read; conversation cache never purged; model catalogues
  re-fetched sequentially for all hosts on returning to the foreground.
- Accessibility: the Goal banner does not open with VoiceOver (`onTapGesture` without an accessibility action).
- UI tests: Swift 6 "main actor-isolated" warnings (annotate the class `@MainActor`).
- Probe: `zcode-probe check` may pick a refusal option when there is no `allowOnce`; raw `${VAR}` substitution in
  scripts (`"` or `\` break the JSON).
