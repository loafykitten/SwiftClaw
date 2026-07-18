# Memory

Persistent, user-visible memory for the assistant: named collections of
small memory entries that both the user and the AI browse, search, and edit
— a first-class Workspace feature, not a settings pane. Per-collection
access controls whether AI edits apply immediately (disclosed with one-tap
undo) or need in-the-moment approval. Governing priority: **a missed
relevant memory is worse than spent tokens** — the design over-includes
everywhere it has a choice.

## Ownership and lifecycle

`MemoryFeatureModel.shared` (`Features/Memory/`) is the thin coordinator:
configured once from `AppBootstrap` with the app `ModelContainer` (no I/O in
construction), it owns the single `MemoryRepository` and
`MemoryPromptBuilder` and exposes availability (`isAvailable` = feature
enabled + configured) to views, tools, and review services.

`MemoryRepository` (`Services/Memory/`) is the `@MainActor` mutation
boundary (the `EmailRepository` precedent — pure SwiftData, no vault/actor
machinery). Every mutation writes a `MemoryActivityEvent` in the same save
and bumps `mutationGeneration`, the prompt builder's cache key. It owns
Inbox ensure-exists, supersession, handle resolution, lexical search, and
the Workspace-tile summary. UI list reads go through `@Query` in views.

## Data model (`Models/`, main local store — registered in both schemas)

- **`MemoryCollection`** — title (a short descriptive sentence), optional
  details, tags, `accessLevel` (`asksFirst`/`writesFreely`), optional
  `scope` (one `WorkspaceFeature`; nil = global), `isPinned`, `isInbox`,
  provenance + timestamps, cascade-owned `entries`.
- **`MemoryEntry`** — one atomic fact (~15–40 tokens) in exactly one home
  collection; tags; provenance (`createdBy`, `sourceChatID`);
  `supersededByID` (facts are superseded, never overwritten — updating adds
  a replacement and stamps the old entry; contradictions stay visible);
  `disclosedAt` (chip crash-safety marker, see Disclosure); `handle` =
  first 8 hex chars of the UUID (model-facing identity — full UUIDs cost
  ~20 tokens against 15–40-token facts).
- **`MemoryProposal`** — a pending/resolved AI-proposed write
  (`NoteEditProposal` pattern: statuses with durable `.applying`,
  `chatID`, `cardPostedAt` drain marker), serving both asks-first chat
  writes and background `propose_memory`. Carries `entryText`, target
  collection or new-collection request (+ requested access level),
  `supersedesEntryID` for proposed updates, scope, tags, summary, source
  provenance (chat vs. which review service). New-collection proposals
  carry seed entries newline-separated in `entryText`
  (`MemoryProposalDispatcher.entryTexts`). No `conflicted` status: memory
  has no base-hash race; a vanished target routes to the Inbox instead
  ("never force-file").
- **`MemoryActivityEvent`** — the audit trail: kind (added/edited/
  superseded/moved/deleted/accessChanged/undone/proposalAccepted/
  proposalDismissed), entry/collection IDs, `snapshotText` (what the
  mutation would otherwise lose), actor, chat, timestamp. Collection-level
  events carry a nil `entryID`.

**Inbox** — a built-in collection for uncertain classification (misfiled
facts are invisible facts). Created lazily by the repository; undeletable,
unscopable, always `writesFreely`.

## Access levels

The AI can always read everything; the access level gates *how* a write
lands, never whether it can happen:

- **AI asks first** — every AI write surfaces as an inline proposal card
  (Accept / Edit / Dismiss) and applies only on acceptance.
- **AI writes freely** — autonomous writes land immediately, disclosed with
  the chip + undo pattern.

New AI-created collections default to `writesFreely` (the
frictionless-capture path); an asks-first creation seeds its initial
entries inside that same accepted proposal. The AI never changes a
collection's access level; switching asksFirst → writesFreely is a
user-confirmed action (`MemoryCollectionEditorSheet`).

UI rule: the **badge carries the meaning, tint only reinforces it** —
explicit labels + distinct symbols + full VoiceOver strings on every
collection row and detail header (`MemoryAccessPresentation`). Color alone
is never the signal.

## Scope and pinning

A collection is global (default) or scoped to one workspace feature. Scope
is an injection-priority hint, not a silo: chat sees scoped collections
under the normal exposure rules; search and the Memory UI cover everything;
background reviews use scope to build a small targeted context. Pinned
collections are always injected — first in every chat exposure tier and in
every review run regardless of scope — the home for cross-cutting durable
context.

## LLM exposure (`Services/Memory/MemoryPromptBuilder.swift`)

Tiered by **measured serialized store size** (`TokenEstimator`, UTF-8
bytes ÷ 4 — the app has no tokenizer and every provider is
OpenAI-compatible), not cleverness. Full injection has zero
retrieval-failure modes:

- **≤ ~40k estimated tokens** (the shipped common case; ~200 entries ≈
  3–8k): the entire store as deterministic compact Markdown — pinned
  collections first, then by `createdAt`; entries as
  `- (8-hex-handle) fact [date]`; superseded entries excluded; access
  level/scope/tags in each collection heading.
- **Above**: a compact index (titles + handles + tags + counts) + pinned
  collections in full, plus per-turn lexical recall of top candidates from
  the latest user message (`recallBlock` — loose thresholds, tag/title
  boosts, mild recency, per-collection diversity cap, conflicting facts
  never deduplicated, pinned skipped as already present).

"Prompt caching" here means *prefix stability*: the block is byte-identical
between mutations (cached on `mutationGeneration`, so edits batch), and
`ChatCompletionService` appends it before the volatile per-turn hints.
`.prependPersona` hoists it into the combined first system message.

Model-facing tools — read tools on `ToolRegistry.shared`
(`search_memory`, `open_memory_collection`), write tools request-bound per
completion with container + chat id (`add_memory`, `supersede_memory`,
`create_memory_collection` in `Services/Memory/Tools/`). The tool surface
is identical for both access levels: the target collection's level routes a
write to an immediate repository apply or a `MemoryProposal`, automatically.

## Writes and disclosure

The invariant: **no memory ever exists that the user didn't watch being
created or explicitly accept.**

- Writes to writes-freely collections show a `.memoryWrite` chip
  (`MemoryWriteChipRenderer`) — one card per turn, one item per write —
  with **View** (read-only peek sheet) and **Undo**. Undo is a hard delete
  (no tombstone; the activity snapshot is the audit trail), un-stamps a
  superseded fact, and stays enabled only while the entry is unmodified and
  unsuperseded (`MemoryEntry.isUndoableWrite`); afterwards the chip keeps
  View and explains why Undo is gone.
- Asks-first writes surface as a `.memoryProposal` card
  (`MemoryProposalCardRenderer`) — **Accept / Edit / Dismiss**; Edit opens
  a prefilled sheet whose save is accept-with-modified-text through the
  same approval path. Dismissals are durable (`.rejected` rows feed review
  suppression).
- `MemoryCardCoordinator` queues disclosures from tools mid-inference and
  drains them after the assistant reply in the same save
  (`NotesProposalCoordinator` pattern). Crash-safety markers make every
  disclosure exactly-once: `MemoryEntry.disclosedAt` for chips,
  `MemoryProposal.cardPostedAt` for cards, both backed by persisted-state
  rehydration queries.
- `MemoryWriteDispatcher` (undo) and `MemoryProposalDispatcher`
  (two-phase approve/reject; entries written on acceptance are marked
  disclosed by the card itself) live in `Features/Chats/ReviewCards/` with
  their renderers; `ReviewActionToken` gained `edit`/`undo`.

## Background review integration (`Services/Memory/`)

Review services are memory *consumers and proposers*, never direct writers:

- **Read recipe** (`MemoryReviewContextBuilder.block(for:)`): pinned
  collections (regardless of scope) + collections scoped to the service's
  feature + recent declined proposal texts ("do not re-propose") — the
  injected text is the dedup. Appended to each service's standalone system
  prompt.
- **`propose_memory`** (`ProposeMemoryTool`) — system-only, built per run
  into each service's scoped registry, never `ToolRegistry.shared`.
  Proposes a finished artifact (exact text, target or new-collection
  request, tags, reason); hard cap of 2 per run enforced in the tool via
  `MemoryProposalRunCollector`.
- **`MemoryReviewProposalRouter`** routes raised proposals after the run:
  into the run's review chat when one exists, else a reusable unarchived
  "Memory suggestions" chat (`Chat.memorySuggestionsTitlePrefix`); it also
  sweeps the source's orphans from runs interrupted before routing.

## UI (`Features/Memory/`)

- **macOS**: three-column `HSplitView` — sidebar (All Memory, Recent,
  Activity, pinned + collections with Inbox surfaced, tag shortcuts),
  searchable entry list, detail column.
- **iOS**: stacked on Workspace's ambient `NavigationStack` (the
  `EmailView.compactThreadLayout` precedent): landing → section list →
  entry detail.
- Search (`MemoryEntryListView`) goes through `MemoryRepository.search` —
  the same seam as the `search_memory` tool — visibly labeled for its scope,
  with tag/access/scope/added-by-AI filters. Superseded entries stay
  visible everywhere except prompt injection.
- Confirmations: deletes (entry and collection, with entry count),
  asksFirst → writesFreely switching. The activity feed
  (`MemoryActivityFeedView`) renders the audit trail with snapshots.

## Fixtures & testing

`MemoryCardFixtureSeeder` (DEBUG, `-SwiftClawSeedMemoryCards`) seeds a chat
with a live chip and two proposal cards for simulator UI verification.
Suites in `SwiftClawTests/Memory/`: repository, settings wiring, prompt
builder (determinism, tier switch, recall), write tools (access routing,
gating), card coordinator + dispatchers (drain idempotency, rehydration,
undo guard, approval paths), review integration (cap, read recipe,
declined suppression, routing + orphan sweep).

## Deliberately excluded from v1 (future extensions)

- Embeddings / semantic search — `MemoryRepository.search` is the seam for
  an index-backed swap when observed paraphrase misses justify it.
- Multi-collection entry references — single home + tags until proven
  insufficient.
- Nested collections.
- Direct memory writes from background runs — `propose_memory` covers it.
- Model-initiated proposal downgrades in writes-freely collections — the
  write path is determined by the collection's access level alone.
- Scheduled consolidation (a MemoryReviewService proposing merges/staleness
  cleanups) — worth building once real stores exhibit sprawl.
