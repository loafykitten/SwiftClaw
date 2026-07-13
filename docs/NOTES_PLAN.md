# SwiftClaw Notes — Implementation Plan

## Context

SwiftClaw gains a **Notes** feature: a markdown vault where plain `.md` files
are always the source of truth, freely importable/exportable to apps like
Obsidian and Apple Notes. The vault is either **app-managed** (App Support
folder; iCloud sync designed-but-dormant, like Calendar's CloudKit) or a
**user-chosen external folder** (possibly a live Obsidian vault). The in-app
AI gets **always-allowed read/RAG search** over notes and can **edit only via
per-request user approval** (proposal diff cards in chat).

Product research (Apple Notes / Obsidian / Bear / iA Writer / NotePlan
sentiment) drove the design principles:

- **Adopt (most-loved)**: local-first file ownership, backlinks (> graph
  view), fuzzy quick switcher, daily-note/quick-capture inbox, source-cited
  AI recall, reviewable AI edit diffs, vault-health surfacing.
- **Avoid (most-hated)**: silent sync loss without version history, capture
  friction, forced methodology, AI as permanent chrome or silent rewriter,
  normalizing markdown syntax the app doesn't own.
- **Safety invariants (non-negotiable)**: byte-preserving round-trip (never
  rewrite wikilinks/callouts/front matter outside the edited range); atomic
  writes with content-hash guards — never silently overwrite an external edit
  (write a conflict copy instead); local revision snapshots outside the
  vault; `.obsidian/` and dotfiles are opaque; display title ≠ filename;
  index is a rebuildable cache, never stored in the vault.

Codebase starting points: a Notes scaffold already exists (`NotesView`/
`NotesSettingsView` placeholders, `settings.notes.enabled`,
`WorkspaceSection.notes` wired in `WorkspaceView`). No search/RAG or
approval-gate infrastructure exists anywhere. The Reminders subsystem is the
feature template. `ChatCompletionService` is the single user-chat inference
call site (proposal cards append there). `ReviewCardPayload` has
forward-compat `ReviewType.unknown` and UUID `ReviewItem.itemID` — extending
it is migration-free.

Decisions locked in with the user: **hybrid local RAG** (FTS5 + on-device
NLEmbedding, RRF fusion), **styled-source editor + reading mode** (not
live-preview), **proposal diff cards** (not blocking approval), **full v1
scope** (wikilinks/backlinks, quick capture + daily note, fuzzy switcher,
Workspace tile + review service). Work happens on the `feature/notes` branch.

## Key decisions

| Decision | Pick | Why |
|---|---|---|
| Markdown engine | Add `apple/swift-markdown` (SPM) for parsing/reading mode/chunking; separate lightweight incremental highlighter for the editor | cmark-gfm correctness + `SourceRange`s for citation byte-offsets and code-block exclusion; editor needs approximate per-paragraph styling, not full re-parse |
| Persistence | SQLite index only; sole new SwiftData model is `NoteEditProposal` in the **main local store** (not the CloudKit-shaped store) | Files are truth; mirrored metadata drifts. Proposals must survive relaunch and are device-local (paths/hashes) |
| FTS | System libsqlite3, external-content FTS5, `tokenize='unicode61 remove_diacritics 2'`; runtime capability check → health, not crash | No new dep; CJK weakness is a documented deferral (trigram follow-up) |
| Embeddings | `NLEmbedding.sentenceEmbedding(.english)` behind a `TextEmbeddingProvider` protocol; graceful FTS-only degrade | On-device/private; protocol seam allows NLContextualEmbedding or remote later (schema stores model_id + dim) |
| Vector search | Brute-force cosine over Float32 blobs in the index actor | Personal vaults ≈10³–10⁴ chunks → sub-10ms; no ANN dep |
| Editor losslessness | NSTextView + `NSTextStorageDelegate` highlighter — **attributes only, never characters**; no NSTextStorage subclass | Round-trip guaranteed by construction; DEBUG assert that `string` is unchanged across styling |
| Proposal cards | Extend existing `ReviewType` (+`.noteProposal`, `.notes`) and `ReviewActionToken` (+generic `.approve`/`.reject`); `ReviewItem.itemID` = proposal UUID; store **full proposed content** not a patch; diff is presentation-only | Reuses card storage/registry/dispatcher; old builds degrade to `.unknown`; hash guard (not patching) is the concurrency defense |
| Dormant sync | iCloud Drive **ubiquity container** for app-managed vault (NOT CloudKit records), gated on entitlement via the existing `SecTaskCopyValueForEntitlement` pattern | Vault is files; iCloud gives NSFileVersion conflicts free; our hash/reconcile layer already treats sync as "another external editor" |
| Search architecture | Content-source-agnostic `Services/Search/` (`source_type`/`source_id` columns); Notes is the first adapter | One column now → email/chat indexing is a follow-up, not a rewrite |

## Phase 1 — Vault foundation (files, safety, settings, onboarding)

User can pick/create a vault, list notes, create/edit with an interim plain
editor, and never lose data. Behind `settings.notes.enabled`.

**Shared utilities** (deliberately outside Notes — cross-feature #5):

- `SwiftClaw/Services/Files/SecurityScopedBookmarkStore.swift` — @MainActor;
  save/resolve bookmarks, `ScopedURL` class stops access on deinit, stale
  re-save.
- `SwiftClaw/Services/Files/FSEventStreamMonitor.swift` — wraps
  FSEventStreamRef (file events, ~0.7s latency, private queue) →
  `AsyncStream`; events are *hints*, consumers re-stat.
- `SwiftClaw/Services/Files/AtomicFileWriter.swift` — temp-write +
  `replaceItemAt`.

**Vault layer** (`SwiftClaw/Services/Notes/Vault/`):

- `VaultConfiguration.swift` — `VaultLocation { appManaged |
  external(bookmarkKey) }` + @MainActor store; `resolveAppManagedRoot()` =
  ubiquity container if entitled else `App Support/SwiftClaw/Notes/Vault/`
  (dormant-sync seam, see §Dormant sync); persistent `vaultID` keys
  index/revisions dirs.
- `NotesVault.swift` — **actor**, the only type touching vault files:
  `enumerate` (ignore rules), `read → NoteFileSnapshot(content, sha256,
  mtime)`, `write(relativePath:content:expectedHash:)` — re-hash before
  write; mismatch → `Name (conflict <timestamp>).md` + `.conflict` result;
  nil hash = create-only; `rename` (no clobber), `delete` (trash).
  Security-scope brackets on every op.
- `VaultIgnoreRules.swift` — skip dotfiles/dirs (`.obsidian`, `.git`),
  non-`.md`, own temp artifacts.
- `NoteRevisionStore.swift` — **actor**; content-agnostic string-keyed
  snapshots to `App Support/.../Revisions/<vaultID>/`, snapshot before every
  mutation, prune (50/note, 30 days).
- `VaultReconciler.swift` — **actor**; consumes monitor stream (1s debounce)
  **plus** full-scan fallback (app activation + 5-min while visible); emits
  `ReconcileDelta { added, modified, removed, renamedPairs }`.

**Repository**:
`SwiftClaw/Services/Notes/Repository/NotesRepository.swift` — @MainActor sole
mutation boundary (per `ReminderRepository`); in-memory `[NoteSummary]`
catalog; applies deltas; posts `.notesStoreDidChange`; create
(sanitized/uniquified filename), save (revision snapshot → hash-guarded write
→ surface `NotesError.externalConflict(copyPath:)`), rename, delete.
`NotesError.swift` — LocalizedError enum.

**UI**: `NotesOnboardingSheet.swift` (two cards: create app vault / choose
existing folder "works with Obsidian vaults", NSOpenPanel + bookmark —
matches `CalendarOnboardingSheet`); rewrite `NotesView.swift` (list column +
search-by-title + New Note; interim TextEditor detail with debounced save +
conflict banner); rewrite `NotesSettingsView.swift` (vault location +
Change/Reveal/Reset, stats).

**Modified**: `SwiftClaw.entitlements`
(+`com.apple.security.files.user-selected.read-write`; caveat: re-signing
voids the debug build's Accessibility grant — affects computer-use
verification only), `AppSettings.swift` (keys in §Settings keys).

**Tests** (`SwiftClawTests/Notes/`): `NotesVaultTests` (round-trip byte
equality, conflict copy + original intact, create-collision, rename),
`VaultReconcilerTests` (injected event stream; fallback catches missed
event), `NoteRevisionStoreTests`, `SecurityScopedBookmarkStoreTests`, one
real-FSEvents integration test (eventual delta, tolerant of coalescing).

## Phase 2 — Markdown engine, styled-source editor, reading mode

- `Package.swift` + `apple/swift-markdown`.
- `SwiftClaw/Services/Markdown/` (shared, not Notes-internal — cross-feature
  #3): `MarkdownDocument.swift` (parse + SourceRanges + heading outline +
  **excluded ranges**: code blocks/spans, front matter);
  `FrontMatterBlock.swift` (byte-preserving line-based `---` block handling;
  `settingValue(_:for:)` replaces/appends **only that key's line**; reads
  `tags:` inline+dash forms; no YAML lib — never normalize what we don't
  understand); `MarkdownRenderedView.swift` (SwiftUI reading mode:
  headings/lists/tables/fenced code/callout-styled quotes, tappable
  wikilinks, relative images via the vault actor).
- `SwiftClaw/Features/Notes/Editor/`: `NoteEditorView.swift`
  (NSViewRepresentable; **controller owns the text — never round-trip through
  @State/Binding**, avoids NSTextView↔SwiftUI feedback loops);
  `NoteEditorController.swift` (@MainActor @Observable: dirty state, 1.5s-idle
  + blur autosave via repository with expectedHash, reconcile-delta handling:
  clean→reload, dirty→non-modal "Keep Mine (conflict copy) / Take Theirs"
  bar); `MarkdownSourceHighlighter.swift` (NSTextStorageDelegate,
  paragraph-scoped restyle, fence-tracking line state machine,
  attributes-only + DEBUG assert); `MarkdownEditorTheme.swift` (honors
  increase-contrast even over Liquid Glass translucency — UX/a11y > HIG per
  requirements).
- `Features/Notes/Reading/NoteReadingView.swift` + Edit/Read toggle (Cmd-E).

**Tests**: `FrontMatterBlockTests` (byte-for-byte corpus: unknown keys,
comments, `---` in body; single-line change), `MarkdownLosslessnessTests`
(Obsidian corpus — callouts, `[[page|alias]]`, `![[embeds]]`, nested tags —
through NSTextStorage + highlighter, `string` identical; simulated edits
change only typed chars), `MarkdownDocumentTests` (outline, excluded ranges).

## Phase 3 — Index & search, backlinks, quick switcher, vault health

**Generic engine** (`SwiftClaw/Services/Search/` — source-agnostic,
cross-feature #2):

- `SQLiteDatabase.swift` — **actor** over the C API (prepared-statement
  cache, WAL, `user_version` migrations; actor-confined connection satisfies
  strict concurrency without `@unchecked`).
- `SearchIndex.swift` — **actor**; schema v1: `documents(source_type,
  source_id, title, uri, content_hash, updated_at, UNIQUE(source_type,
  source_id))`, `chunks(document_id, ordinal, heading_path, byte_start,
  byte_end, content)`, `chunks_fts` (external-content FTS5, unicode61),
  `embeddings(chunk_id, model_id, dim, vector BLOB)`;
  upsert/remove/ftsSearch/vectorSearch/rebuild; FTS5 runtime check → health.
- `TextChunker.swift` (split at headings, ≤~1,500 chars, heading path + byte
  range; no overlap in v1), `TextEmbeddingProvider.swift`
  (+`NLSentenceEmbeddingProvider`, nil → FTS-only), `HybridSearcher.swift`
  (RRF: `Σ 1/(60+rank)` → `SearchHit{document, chunk, headingPath, snippet,
  score}`).

**Notes indexing** (`Services/Notes/Indexing/`): `NotesIndexer.swift` (actor;
reconciler deltas → read → parse → chunk → embed → upsert, hash
short-circuit, `rebuildAll()`; DB at `App
Support/.../Index/<vaultID>/index-v1.sqlite`); `NoteLinkGraph.swift`
(`links`/`tags` tables; `WikilinkScanner`/`TagScanner` in
`Services/Notes/Parsing/` operate **outside excluded ranges**; stem-based
Obsidian resolution; unresolved = broken links; backlinks = reverse query);
`NotesHealthSummary.swift` (broken links, conflict copies, freshness,
FTS/embedding availability).

**UI**: `SwiftClaw/Shared/FuzzyMatcher.swift` (reusable subsequence matcher +
matched ranges — cross-feature #4; switcher itself is **Notes-scoped v1**,
Cmd-O); `NotesQuickSwitcher.swift`; `BacklinksPanel.swift` (trailing
inspector); hybrid search results in `NotesView` (snippets + heading paths);
wikilink autocomplete on `[[` in the editor; vault-health banner + settings
detail (Rebuild Index, broken-links list).

**Tests**: `SQLiteDatabaseTests`, `SearchIndexTests`, `TextChunkerTests`
(byte ranges re-slice source exactly), `HybridSearcherTests` (deterministic
RRF with stubs), `NotesIndexerTests` (code-fenced wikilink not extracted),
`NoteLinkGraphTests`, `FuzzyMatcherTests`; embedding tests skip when
NLEmbedding unavailable.

## Phase 4 — AI read tools (always allowed)

- `Services/Notes/Tools/SearchNotesTool.swift` — `search_notes(query,
  limit=8)` → compact cited digest: `[[note: relative/path.md § Heading]]` +
  snippet per hit.
- `Services/Notes/Tools/ReadNoteTool.swift` — `read_note(path, heading?)` →
  verbatim content (front matter included), length-capped with truncation
  notice.
- Gating: `isConfigured = notesEnabled && vault configured && index
  available` — tools vanish from every chat when Notes is off via the
  existing `ToolRegistry.availableTools` filter; **not**
  `requiresExplicitEnable` (read is always allowed; matches `WebSearchTool`
  posture).
- Modified: `ToolRegistry.shared` (+both), verify `ToolsView` listing.
- Tests: citation format, caps, `notConfigured` when disabled.

## Phase 5 — Proposal diff cards (the approval gate; first in the app — designed for reuse)

- `Models/NoteEditProposal.swift` — @Model, main store: id (.unique), kind
  (`create|edit|append|rename`), notePath, newPath?, baseContentHash? (nil =
  create), proposedContent?/appendText?, summary, status
  (`pending|applied|rejected|conflicted|expired`), createdAt, resolvedAt?,
  chatID?. Add to `mainSchema`/`fullSchema` in
  `SwiftClawModelContainerFactory.swift` (lightweight migration).
- `Models/ReviewCardPayload.swift` — +`ReviewType.noteProposal` and `.notes`;
  +`ReviewActionToken.approve`/`.reject` (generic names for future
  email-draft reuse).
- `Shared/DiffEngine.swift` — Myers line diff → `[DiffLine]` (shared for
  future email drafts — cross-feature #1).
- `Services/Notes/Tools/ProposeNoteEditTool.swift` +
  `ProposeNoteCreateTool.swift` — capture current snapshot hash, insert
  proposal, queue ID on the coordinator, return "Proposed edit to X —
  awaiting user approval". **Never writes files.**
- `Services/Notes/Proposals/NotesProposalCoordinator.swift` — @MainActor
  @Observable queue; **drained in `ChatCompletionService` right after
  `chat.appendMessage(role: .assistant, ...)`, before `modelContext.save()`**
  — appends the card `ChatMessage` to the same chat. Deterministic (tool-loop
  chats are always non-streaming `complete()`).
- `Features/Chats/ReviewCards/NoteProposalCardRenderer.swift` —
  kind/path/summary header, collapsible diff (current vs proposed; accessible
  "line added/removed" labels), Approve/Reject, status states incl.
  conflicted-with-explanation.
- `Features/Chats/ReviewCards/NoteProposalDispatcher.swift` —
  `ReviewActionDispatcher`; `.approve`: **re-read file and re-check
  `baseContentHash` at approve time** → mismatch: mark `conflicted`, post
  "note changed since proposed — not applied; ask me to re-propose"; match:
  apply via repository (revision snapshot first), mark applied, post outcome.
  `.reject`: mark + brief outcome. Register in `ReviewCardRendererRegistry` +
  chat dispatcher provider.
- Tests: `NoteProposalDispatcherTests` (the critical suite:
  approve-after-external-edit → conflicted + file untouched; clean approve →
  applied + revision exists; reject; double-approve idempotent),
  `DiffEngineTests`, `ProposeNoteEditToolTests` (creates record, never
  writes), payload coding.

## Phase 6 — Quick capture, daily note, Workspace tile, scheduled review

- `Services/Notes/QuickCapture/NotesQuickCaptureService.swift` (@MainActor,
  mirrors `ReminderQuickEntryService`): timestamped bullet append to today's
  daily note (`YYYY-MM-DD.md` in `settings.notes.dailyNoteFolder`, minimal
  template) or standalone note; capture field in Notes toolbar + Workspace
  tile action. `DailyNoteResolver.swift` pure + tested.
- Review trio per Reminders template (`Services/Notes/Review/`):
  `NotesReviewFetchTool` (system-only digest: unchecked daily-note items,
  conflict copies, broken links, recent notes, index health),
  `NotesReviewNotifyTool` (review chat + `.notes` card),
  `NotesReviewService.runOnce` (scoped registry, `.standalone`,
  completeProvider seam, unread guard). `NotesWorkflowManager.swift` timer
  loop per `ReminderWorkflowManager`; started from `AppBootstrap`/
  `ContentView`. **Review scope kept modest** (research: no AI-as-chrome):
  vault hygiene + triage only, never unprompted content edits; default
  interval manual/daily.
- `Features/Workspace/WorkspaceNotesSummary.swift` + stats tile (note count,
  captured-today, health badge); `NotesReviewCardRenderer.swift`.
- Modified: `NotesSettingsView` (review interval + Review Now + daily-note
  folder), `AppSettings`, `AppBootstrap`, `ContentView`,
  `ReviewCardRendererRegistry`.
- Tests mirror the Reminders suites: review service/notify/quick-capture/
  daily-note/workspace-summary/workflow-manager.

## Phase 7 — Docs, hardening, polish

- `docs/features/NOTES.md` (architecture, safety invariants, index schema,
  proposal flow — REMINDERS.md depth); update `docs/conventions/TOOLS.md`
  (shared tools + proposal-gate pattern) + `docs/architecture/OVERVIEW.md`;
  **delete** `docs/memory/notes-implementation.md`; add Notes entries to
  `docs/testing/USER_FACING_TESTS.md` (end-of-feature step per AGENTS.md).
- Performance pass: generated 5,000-note fixture (index < 30s target, search
  latency, 1MB-note editor — cap styling beyond size threshold).
- Accessibility pass: editor VoiceOver, diff-card labels, keyboard-only
  switcher.
- Minimal per-note "Revisions…" sheet (restore-as-conflict-copy).

## Dormant sync (app-managed vault)

iCloud Drive ubiquity container, not CloudKit records: the vault is files;
ubiquity keeps files as files, `NSFileVersion` gives conflict versions free,
and the hash/reconciler layer already treats sync as an external editor. Seam
ships in Phase 1 (`resolveAppManagedRoot()` + entitlement check per
`SwiftClawModelContainerFactory.hasCloudKitEntitlement`); with entitlement →
ubiquity `Documents/Vault` + `NSFileCoordinator` added inside the
`NotesVault` actor (single choke point); commented re-enable recipe in the
entitlements file next to the CloudKit one. No sync code enabled in v1.

## Cross-feature leverage (seams designed in; migrations are follow-ups, NOT in scope)

1. **Approval gate** → generic `.approve`/`.reject` tokens, shared
   `DiffEngine` + diff subview, coordinator-queue pattern. Follow-up:
   email-draft / calendar-edit proposals.
2. **Hybrid index** → `Services/Search` takes no Notes types. Follow-up:
   email/chat-history adapters, app-wide semantic recall tool.
3. **Markdown engine** → `Services/Markdown` shared. Follow-up: swap the
   Chats transcript renderer (gains lists/tables/code blocks it currently
   lacks).
4. **FuzzyMatcher** in `Shared/`. Follow-up: app-global Cmd-K switcher.
5. **File utilities** (`Services/Files/`) shared from day one. Follow-up:
   import/export, watched folders.
6. **Revision store** content-agnostic. Follow-up: email-draft history.

## Settings keys

`settings.notes.vaultLocationType`, `.vaultBookmarkKey`, `.vaultID`,
`.dailyNoteFolder`, `.defaultNewNoteFolder`, `.reviewInterval`,
`.lastReviewCompletedAt`, `.embeddingsEnabled` (+ `SettingsStorage`
helpers/defaults per SETTINGS.md); `Notification.Name.notesStoreDidChange`,
`notesReviewScheduleDidChange`.

## Risks & mitigations

NSTextView↔SwiftUI loops → controller owns text, identity-only from SwiftUI.
FSEvents misses/coalescing → hints + rescans + hashes. FTS5 CJK weakness →
documented, trigram follow-up. NLEmbedding unavailable/mediocre → provider
protocol, FTS-only degrade, health-surfaced. Proposal races user edits →
approve-time hash re-check + pre-apply revision snapshot. Index corruption →
rebuildable cache, Rebuild button. Entitlement re-sign voids the debug
build's Accessibility grant → affects computer-use verification only.

**Deferred from v1**: wikilink rename back-propagation (corruption risk;
health surfaces broken links instead), graph view, CJK trigram table,
NLContextualEmbedding, tag-editing UI, rich history browser, app-global
switcher, editor attachment embedding.

## Verification

Per phase: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test
-derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO
-only-testing:SwiftClawTests/Notes | xcbeautify --quiet` (+ touched suites,
e.g. `.../Chats` in Phase 5), a full build, and the phase's manual script.
Every phase leaves `main`-mergeable behavior behind `settings.notes.enabled`.

Key end-to-end manual checks: (P1) edit a note in TextEdit while dirty in-app
→ conflict copy, no silent overwrite; (P2) edit an Obsidian note with
callouts + front matter, `git diff` the vault externally → only intended
lines changed; (P3) index a few-hundred-note Obsidian vault, exact vs
paraphrase search, backlinks on a hub note, broken link surfaces in health;
(P4) chat "what do my notes say about X?" → cited answer; disable Notes →
tools gone; (P5) propose edit → externally modify the file → Approve →
conflicted + file intact → re-propose → applied; (P6) quick capture lands in
today's daily note; review surfaces conflicts/broken links.
