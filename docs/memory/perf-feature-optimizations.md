# Performance optimizations across features

**Started:** 2026-07-18  **Status:** in progress

## Goal

Land verified performance fixes across Email, Calendar, Reminders, Notes,
Memory, Chat, and Home/Workspace on branch `perf/feature-optimizations`,
without user-visible behavior changes except two the user approved:
a configurable chat context budget (default 200k tokens) and day-phase
caching of the Home greeting/blurb. Done = all batches merged, macOS build
and full test suite green, findings below addressed or explicitly skipped.

## Current state

Wave 0 plus batches W1 (Notes editor), W3 (Memory), W4 (Reminders),
W5 (Calendar), and W6 (Email) are implemented, reviewed, tested, and merged
onto `perf/feature-optimizations`; the full macOS test suite passed on the
integrated branch at the W1+W3+W4+W5 point, and W6's ten covering suites
passed after merge-time fixes. W2 (Notes services) and W7 (Chat) codex runs
are in flight; W8 (Home/Workspace) waits on W7's async attachment API.

Merge-time findings worth remembering:
- codex's sandbox cannot run xcodebuild (CoreSimulatorService); every batch
  is built/tested by the reviewer afterwards. Expect small compile fixes:
  default MainActor isolation inference (`nonisolated` needed on helper
  classes), missing `return` after adding statements to implicit-return
  bodies, `nil` needing contextual types.
- Email review selection: threads fetched via relationship predicates can
  serve stale attribute snapshots — archived/trashed exclusion must live in
  the fetch predicate, not in-memory rechecks (regression was caught by
  `EmailReviewFetchTests`, fixed by restoring visibility conditions with a
  folders-requested fallback).
- W5's ICS COUNT regression tests had swapped fixtures/expectations
  (fixed); recurrence-end predicate is now `>=` at the window edge.

## User decisions (do not re-litigate)

- **Chat context budget**: implement trimming — drop old turns beyond a
  configurable token budget, default 200k (`SettingsKeys` +
  `SettingsStorage` + a settings UI control), and attach image data only
  for the most recent user turn. Plus behavior-safe fixes (off-main image
  reads, cached encoded data).
- **Home greeting/blurb**: cache keyed by day phase
  (morning/afternoon/evening) + persona + model + location; regenerate when
  any key changes, not on every visit.

## Verified findings and decisions

### Cross-cutting (Wave 0 — implement first, directly on the branch)

- `Shared/SearchQuery.swift:11` — `matches` re-tokenizes the query for every
  candidate. Add a compiled form (tokenize once, reuse per candidate);
  update call sites: `Models/Chat.swift:162` (`matchesSearch` — also guard
  so `searchValues`/message bodies aren't materialized when search is
  inactive), `Models/Email.swift:114` (same guard; empty search currently
  HTML-strips every message body via `plainTextBody`),
  `Services/Memory/MemoryRepository.swift:498`.

### Notes (Batch W1: editor; Batch W2: services)

W1 (editor, per-keystroke costs):
- `Features/Notes/Editor/MarkdownSourceHighlighter.swift:70` — per-edit
  full-document UTF-8 count, `FenceStateMachine.recompute` over every line,
  and `lineNumber` prefix scan. Cache UTF-8 size/line starts/fence state,
  update incrementally, propagate fence state only until convergence.
  Needs regression tests (fence insert/delete, large-doc mode threshold).
- `Features/Notes/Editor/WikilinkCompletion.swift:51` — trigger scan walks
  to document start one UTF-16 unit at a time on every text/selection
  change. Restrict to current line, use `NSString.range(of:options:range:)`.
  Existing behavior (rejection of `]`, `|`, `#`, newline in query) must hold.

W2 (services):
- `Services/Notes/Indexing/NoteLinkGraph.swift:179` — link resolution is
  O(links × notes) with repeated normalization. Build exact-path and stem
  dictionaries once per query; preserve ambiguity semantics (unique match
  only).
- `Services/Notes/Vault/NoteRevisionStore.swift:103` — listing loads every
  full snapshot; sheet shows a 240-char preview. Return metadata + bounded
  preview; load full content only on restore (keep "revision not found"
  error path).
- `Services/Notes/Repository/NotesRepository.swift:446` — `upsert` rebuilds
  a dictionary of all notes + full re-sort per autosave. Replace in place
  for same-path updates; binary-insert for creates/renames preserving
  `catalogOrder`.
- `Services/Markdown/MarkdownRenderedView.swift:27` — parses markdown in
  `body`, non-lazy VStack, `ForEach(id: \.offset)`. Cache an immutable
  render model keyed by source; `LazyVStack` for blocks. Watch: cross-block
  text selection behavior; shared component (used beyond Notes).
- `Services/Search/SearchIndex.swift:248` — `vectorSearch` materializes
  every embedding row incl. chunk/document content, then sorts all. Stream
  lean rows, bounded top-K, hydrate winners only. (No approximate index —
  out of scope.)
- `Features/Notes/NotesFeatureModel.swift:417` (+165, 534),
  `Services/Notes/Repository/NotesRepository.swift:162`,
  `VaultReconciler.swift:109` — activation/reconciliation can read+hash
  every note several times (cold reconciler treats all notes as added;
  autosave FSEvents bursts rescan everything). **Scope conservatively**:
  eliminate the redundant post-bootstrap rescan and skip re-indexing when
  the indexed hash matches `NoteSummary.sha256`; prime reconciler
  `knownState` from the loaded catalog only if monitoring starts before
  priming (no missed-external-edit window). Full metadata-cache rework is
  out of scope.

### Memory (Batch W3)

- `Features/Memory/MemoryEntryListView.swift:16,49,135` — the `entries`
  `@Query` is unread but IS the view's invalidation source (repository
  search isn't tracked for inserts/deletes); `visibleEntries` (full-store
  fetch + scan) evaluates twice per render. Fix: make `MemoryRepository`
  `@Observable` (it already has `mutationGeneration`), read
  `mutationGeneration` in body for invalidation, drop the heavy `@Query`,
  compute results once per render.
- `Services/Memory/MemoryRepository.swift:498` — `search` always fetches
  the full store; add limit support so Recent (30) and `search_memory` can
  stop early.
- `Services/Memory/MemoryPromptBuilder.swift:204` — `recallBlock` scans and
  scores every entry per sent message on the main actor. Keep the sync
  signature (avoids call-site churn in ChatCompletionService); cache
  normalized Sendable candidates keyed by `mutationGeneration`; bounded
  top-K selection preserving score-then-UUID ordering and the
  per-collection cap.
- `Services/Memory/MemoryPromptBuilder.swift:68` — `exposure()` builds and
  discards the full-store block even for index tier. Cache per-collection
  serialized fragments + byte counts keyed by collection ID/`updatedAt`;
  keep exact byte accounting so the tier boundary doesn't move.
- `Services/Memory/MemoryRepository.swift:214,385` — collection delete does
  one fetch per entry for superseded-stamp clearing. Batch: collect IDs,
  one predicate fetch (or fetch all non-nil stamps once + Set filter).
- `Features/Memory/MemoryView.swift:27,41` — root re-derives
  pinned/unpinned/allTags per access, scanning all entries (JSON tag
  decode). Stage derivations once per body; cache the tag index by
  `mutationGeneration`; drop the root-level full entry retention if a
  targeted lookup suffices for selection resolution.
- `Features/Memory/MemoryActivityFeedView.swift:48` — unbounded `@Query`
  over the whole never-pruned audit log. Windowed `FetchDescriptor`
  (recent window + fetchLimit) with "Load Earlier" pagination.

### Reminders (Batch W4)

- `Services/Reminders/Repository/ReminderRepository.swift:230` +
  `Import/AppleRemindersImporter.swift:78` + `ICS/ICSTodoTransfer.swift:39`
  — imports `save()` + notify per reminder. Bulk-upsert: prefetch existing
  external identifiers once, apply all, save/notify once (chunk ~250–500
  for very large imports; chunked partial-commit is acceptable).
- `ReminderRepository.swift:436` — orphan sweep fetches per log. Build
  surviving-master ID `Set` once; run after parent-ID remapping.
- `Features/Reminders/RemindersView.swift:15` +
  `ReminderListDetailView.swift:44,64` — unbounded `@Query` re-filtered/
  re-sorted per minute tick (`TimelineView(.everyMinute)`), completed
  history included. Query pending masters separately; load completion
  history predicated on selected list / Completed visibility; compute
  rows/counts once per update. Preserve completed one-offs (no
  `parentReminderID`).
- `ReminderRepository.swift:134` — `pendingReminders()` fetch-all +
  in-memory sort. Predicate-backed descriptors excluding completed/log
  rows; alert (`ReminderAlertScheduler.swift:160`) and review callers add
  their windows/limits. Keep undated + overdue inclusion.
- `Features/Reminders/Import/RemindersOnboardingSheet.swift:124` — ICS
  read+parse synchronous on main. Parse off main; **security-scoped
  resource access must span the async read** (start/stop around the await,
  not a sync `defer`).
- `Services/Reminders/Review/ReminderReviewService.swift:175` — post-review
  stamping fetches per ID. One predicate fetch for all collected IDs.

### Calendar (Batch W5)

- `Services/Calendar/Repository/CalendarRepository.swift:259` + import
  sheets — per-event fetch/save/notify during import (same fix shape as
  Reminders W4; ICS read+parse off main).
- `Features/Calendar/CalendarView.swift:18,56,145` — unbounded event
  `@Query`; every minute tick re-expands recurrences, re-sorts, re-queries
  overlay. Child view with window-bound queries matching
  `CalendarRepository.occurrences(in:)` predicates (one-offs intersecting
  window + viable recurring masters); cache expansion until rows/interval
  change; minute tick drives only `now`-dependent styling and reminder
  chips. **`@Query` predicates fix at init — re-key the child by visible
  window (e.g. `.id(anchor/day)`) so window changes rebuild it.**
- `Services/Calendar/Recurrence/RecurrenceExpander.swift:171` +
  `CalendarRepository.swift:233` — COUNT series always expand from origin
  and are always fetched (`recurrenceEndDate = nil`). At save/import,
  compute the end date **by running the expander once to its final
  occurrence** (identical BY-part/DST semantics), persist, and backfill
  existing rows (one-time migration pass). Regression tests mandatory —
  a wrong end date hides valid occurrences.
- `Services/Calendar/Overlay/CalendarOverlayProvider.swift:62` — EventKit
  queried synchronously every render, twice in week/day mode. Cache by
  (interval, `changeVersion`); derive the non-draggable ID set from the
  same result; invalidate on `EKEventStoreChanged`/activation/interval.
- `Features/Calendar/Grid/CalendarMonthGridView.swift:26,84` — both
  grouping dictionaries rebuilt per day cell (~35–42×). Compute once in
  `body`, pass down.
- `Features/Calendar/Grid/CalendarTimelineView.swift:185,305` — every drag
  tick recomputes every day's layout frames. Precompute `framesByDay`
  stable across `dragState` changes (or isolate gesture preview in a child
  without layout ownership).
- `Services/Calendar/CalendarAlertScheduler.swift:173` +
  `Review/CalendarReviewFetchTool.swift:74` — N+1 event fetches. Bulk-fetch
  unique IDs into `[UUID: CalendarEvent]`.
- `Features/Calendar/Editor/CalendarEventEditorSheet.swift:31` —
  `allowsRecurrence` fetches SwiftData per body eval while typing. Set once
  in `loadDraft()`.
- **Skipped**: timeline column assignment O(n²)
  (`CalendarTimelineLayoutEngine.swift:75`) — real but only matters with
  hundreds of simultaneously overlapping events; min-heap rewrite not worth
  the risk.

### Email (Batch W6)

- `Services/Email/Repository/EmailRepository.swift:272` (`resolveThreads`)
  called from `Sync/MailSyncWorker.swift:358` — full-store refetch +
  recluster of every account on any inserted message. **Scope: clustering
  is already per-account — restrict the rebuild to accounts that had
  inserts** (fetch only that account's messages/threads). Keep full rebuild
  as a repair path. NOT the report's incremental per-cluster rewrite (too
  risky vs. documented thread-identity semantics). Thread-identity tests
  must pass unchanged.
- `Features/Email/EmailAccountScope.swift:113` + `Models/Email.swift:114`
  — empty search runs `matchesSearch` per thread, eagerly materializing
  `searchValues` (HTML-stripping bodies). Early-return when search
  inactive (Wave 0 guard covers the model side); debounce input; memoize
  `plainTextBody` per message if it's a computed HTML strip (verify at
  implementation).
- `EmailRepository.swift:801` + `EmailAttachmentStore.swift:24` —
  attachment bytes written synchronously inside the main-actor upsert.
  Write files off main before `MainActor.run`; pass prepared relative
  paths in; clean up orphan files if the save fails; keep filename
  sanitization.
- `MailSyncWorker.swift:404` + `EmailRepository.swift:566,615` — flag and
  deletion reconciliation each fetch + scan the mailbox (two fetches, up
  to two saves). Single fetch, one loop, one save. Preserve synthetic Sent
  rows and Draft hard-deletion.
- `Services/Email/Repository/EmailReviewSelection.swift:56` +
  `Review/EmailReviewFetchTool.swift:70` — review fetches all candidates
  before applying the limit, then pretty-prints JSON on main. Fetch
  override categories uncapped + ordinary candidates with `fetchLimit`;
  JSON-encode off main. Preserve unread/flagged/notated override and
  suppression rules exactly.
- `Services/Email/MailClient/SwiftMailClient.swift:121` — first sync
  fetches metadata for the entire mailbox then keeps newest 500.
  Investigate SwiftMail API for UID/sequence-range-limited listing; if the
  API can't express it, document and skip. Account for sparse UIDs.
- `Services/Email/Sync/MailSyncScheduler.swift:118` + `MailSyncWorker`
  (`syncOnce` has no coalescing; actors are reentrant across awaits) —
  overlapping sync passes. Store the in-flight task; all callers await it.
- `Services/Email/Review/EmailReviewDescriptors.swift:25,90` — a
  `DateFormatter` per message. One shared formatter.

### Chat (Batch W7)

- `Features/Chats/ChatCompletionService.swift:61,69,83` — three
  `chat.sortedMessages` sorts per send; review-card payloads JSON-decoded
  for every chat (line 61 runs unconditionally). One snapshot; decode
  cards only in the email-review branch.
- `Features/Chats/ChatsView.swift:17,29` + `Models/Chat.swift:98,162` —
  sidebar sort comparator sorts each chat's messages
  (`latestVisibleMessageDate`) per comparison; search materializes all
  message bodies. Persist `latestVisibleMessageAt` on `Chat` (maintained at
  message append/edit/visibility change; backfill nil → derive lazily on
  first sort); Wave 0 guard covers the search side.
- `Features/Chats/Markdown/ChatMarkdownView.swift:35,145` +
  `ChatMarkdownBlockParser.swift:84` — `citations` (full-message scan)
  recomputed per block; blocks reparsed per body. Parse once into an
  immutable presentation value cached by exact content (safe today:
  `streamCompletion` has no production callers — verified).
- `Features/Chats/ReviewCards/NoteProposalCardRenderer.swift:97,247` +
  `Shared/DiffEngine.swift:51` — Myers diff computed synchronously on
  expand; non-lazy line rendering. Compute off main into state (cancel
  stale work); `LazyVStack` inside bounded scroll for large diffs.
- `Features/Chats/ChatsView.swift:712,721` — `scrollTrigger` builds a
  transcript-sized string (sorting + attachment JSON decode per message)
  and `transcriptItems` re-sorts. One sorted snapshot per body; derive the
  trigger from last message ID/content length + generation/error state.
- **Context budget (user-approved behavior change)**:
  `ChatCompletionService` + `Services/Inference/InferenceService.swift:51`.
  Add `SettingsKeys.chatContextTokenBudget` (default 200_000) +
  `SettingsStorage` accessor + settings control. Estimate with the existing
  `TokenEstimator`; keep system content + newest turns within budget, drop
  oldest first; attach image data only for the most recent user turn.
  Cache encoded image data per attachment; read files off the main actor.
  **Invariant to preserve (user-raised)**: images must never go to
  non-vision models. This already holds at two layers
  (`ChatCompletionService.swift:47` `canUseImages`, and
  `InferenceService.swift:159` gating `chatParam` image data, disk read
  included) — the budgeting/caching rework must keep both gates, and W7
  adds a test asserting a non-vision model selection produces no image
  payloads.
- `ImageAttachmentStore.finalizeDraftAttachments` (`ChatsView.swift:869`,
  `ImageAttachmentStore.swift:125`) — synchronous file copies on main at
  send. Async finalization (actor or detached I/O), submission stays busy
  and retains the draft until success; update the ChatsView call site.
  (HomeView call site: Batch W8, after W7 merges.)

### Home / Workspace (Batch W8 — runs after W7 merges; depends on its APIs)

- `Features/Workspace/WorkspaceView.swift:46,89` — app-shell-level
  `@Query` over all emails; any email mutation rebuilds the whole
  Workspace body. Move into the email widget (pattern already used by the
  calendar/reminders widgets) with an `!isArchived && !isDeleted`
  predicate.
- `Features/Workspace/WorkspaceEmailSummary.swift:18` +
  `Models/Email.swift:55` — `isReviewFlagged`/`hasReviewNote` each rebuild
  `reviewableMessages` (two relationship sorts per thread). One pass
  computing all counts.
- `WorkspaceView.swift:477` — calendar widget queries all events and
  expands recurrences in body. Windowed queries matching
  `CalendarRepository.occurrences(in:)`; **re-key the widget by current
  day** so the fixed-at-init predicate window rolls; drop the second sort
  in `WorkspaceCalendarSummary.swift:20`.
- `WorkspaceView.swift:530` + `WorkspaceRemindersSummary.swift:30` —
  minute-tick scan includes completed one-offs; five separate passes.
  Extend predicate with `completedAt == nil` (keep undated pending
  reminders — they can be flagged); single-loop counts.
- `Features/Home/HomeView.swift:91` — attachment finalization call site →
  adopt W7's async API (same draft-retention rules).
- `HomeView.swift:69` + `DayGreeting/HomeDayGreetingView.swift:28` —
  greeting/blurb regenerate per visit. **User decision**: cache keyed by
  day phase + persona + model + location; explicit refresh still allowed
  if a control exists.

## Execution plan

Implementation is delegated to gpt-5.6-sol via `codex exec` (codex 0.144.x:
pass `-m gpt-5.6-sol` explicitly; fold targets into the prompt). Sol agents
work alone (no sub-agents). Claude reviews every diff, builds, and tests.

1. **Wave 0** (Claude, direct on branch): `SearchQuery` compiled query +
   call-site guards. Build + targeted tests, commit.
2. **Wave 1** (parallel, one git worktree per batch off the branch):
   W1 Notes-editor, W2 Notes-services, W3 Memory, W4 Reminders,
   W5 Calendar, W6 Email, W7 Chat. Worktrees prevent codex edit collisions;
   batches are file-disjoint by construction.
3. Review each diff (Claude), run the batch's test suites, merge back
   sequentially into `perf/feature-optimizations`, resolving overlaps
   (expected: none; W3's prompt-builder work doesn't change
   ChatCompletionService signatures).
4. **Wave 2**: W8 Home/Workspace (needs W7's async attachment API).
5. Full macOS build + full test suite; fix fallout; final review pass
   (`codex review` as an independent check).

Build/test (from repo root):
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build|test -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO` (pipe through `xcbeautify --quiet`).

Constraints for every batch: keep AppKit/UIKit behind `#if os(...)`; both
platforms must keep building; previews must not touch
Keychain/network/SwiftData; performance-only — no drive-by refactors;
new caches must have explicit invalidation keyed to existing change
signals (`mutationGeneration`, content equality, `changeVersion`); add
regression tests where the plan says so.

## Next steps

1. Commit this plan.
2. Wave 0: implement compiled `SearchQuery` + call-site guards; build,
   test, commit.
3. Create seven worktrees; launch W1–W7 codex runs in parallel; review,
   test, merge sequentially.
4. Wave 2: W8; review, test, merge.
5. Full build + full test suite; `codex review` of the branch diff;
   update this file; delete it in the final commit.

## Files touched

None yet (plan only).
