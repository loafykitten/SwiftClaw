# Memory

> **Status: settled design, implementation planned — not yet implemented.**
> This doc captures the agreed shape of the feature. The implementation plan
> (research findings, key decisions, phases) is `docs/MEMORY_PLAN.md`; as code
> lands, this doc evolves into the standard feature doc and gains file/type
> references.

Persistent, user-visible memory for the assistant: named collections of small
memory entries that both the user and the AI browse, search, and edit —
per-collection access controls whether AI edits apply immediately or need an
in-the-moment grant. A first-class Workspace feature, not a settings
pane. The governing priority: **a missed relevant memory is worse than spent
tokens** — the design biases toward over-inclusion everywhere it has a choice.

## Data model

**Collection** — a named group of related memories.

- Stable internal ID; never the model-facing or user-facing handle for
  identity. Titles are freely editable without breaking anything.
- `title`: a short descriptive sentence — tells both the user and the model
  what the collection holds and when to open it (e.g. "Preferences for how
  email review should behave").
- Optional longer `details` description, plus cross-cutting `tags`.
- `accessLevel`: see below.
- `scope`: global (default) or one workspace feature — see below.
- `isPinned`: see below.
- Provenance (created by user or AI) and timestamps.

**Memory entry** — one atomic fact, short (target ~15–40 tokens).

- Lives in exactly one home collection. Tags handle cross-cutting themes;
  multi-collection references are deliberately excluded from v1.
- Provenance: added by user or by the AI, with a source-conversation link and
  created/updated timestamps.
- `supersededBy` link: facts are **superseded, never overwritten or silently
  merged**. Updating a fact adds a replacement and marks the old entry
  superseded; contradictions the model cannot resolve stay visible with
  timestamps. Deletion is user-initiated.

**Inbox** — a built-in collection for uncertain classification, so the AI
never force-files a fact into a wrong home just to save it. Misfiled facts are
invisible facts; the inbox is the pressure valve.

## Access levels

The AI can always **read** everything, and can always write — the access level
gates *how* a write lands, not whether it can happen:

- **AI asks first** — every AI write needs an in-the-moment grant: in chat the
  write surfaces as an inline memory proposal (the same finished artifact as
  `propose_memory`) that the user accepts, edits, or dismisses before anything
  is saved.
- **AI writes freely** — autonomous writes land immediately, disclosed with
  the chip + undo pattern below.

The user always has full read/write everywhere. The AI can create collections
of either level; new collections default to "AI writes freely" (the
frictionless-capture path), and creating an "asks first" collection may seed
initial entries within that same granted transaction. The AI never changes a
collection's access level itself — switching "asks first" → "writes freely"
is always a user-confirmed action.

UI rule: the **badge carries the meaning, tint only reinforces it**. Explicit
labels ("AI asks first" / "AI writes freely", raised-hand vs. pencil-sparkle
icon) on every collection row and repeated in the collection-detail header,
with full VoiceOver strings ("Travel preferences, AI asks before changing
memories"). Color alone is never the signal (WCAG, dark mode, color filters).

## Scope

A collection is global (default) or scoped to one workspace feature (email,
calendar, reminders, notes — mapping onto `WorkspaceFeature`). Scope is an
**injection-priority hint, not a silo**:

- Interactive chat sees scoped collections under the normal exposure rules.
- Global search and the Memory UI cover everything; scope is a chip/filter.
- Background review services use scope to build a small, targeted context
  (below) instead of injecting the whole store into every fresh-context run.

One scope per collection in v1. No combined "all workspace" scope — the whole
benefit is per-feature targeting.

## Pinned collections

Pinned collections are always injected: first in every chat exposure tier, and
included in every background review run regardless of feature scope. They are
the home for cross-cutting durable context (identity, standing preferences,
active goals) that would otherwise get duplicated into every feature scope.
Pinning is user-controlled and visible in the UI.

## LLM exposure

Tiered by **measured serialized store size**, not cleverness. Full injection
has zero retrieval-failure modes, which serves the over-inclusion priority;
progressive disclosure suffers from "the model can't search for a fact whose
relevance is only apparent after reading it."

| Measured store | Always in context | Automatic recall | Model tools |
|---|---|---|---|
| ≤ ~40k tokens (expected common case; ~200 entries ≈ 3–8k) | Entire store | — | Optional |
| Above ~40k tokens | Compact index (titles + tags + counts) + pinned collections | Every substantive turn: generous candidate injection (loose thresholds, collection diversity preserved) | Search + open-collection as an **expansion** mechanism — a second chance, never the only chance |

- Search (model- and user-facing) covers **entry bodies**, not just titles and
  tags — title-only search is a hard recall ceiling. Lexical + tag search in
  v1; embeddings deferred until observed paraphrase misses justify them.
- Prompt-cache placement: the stable store/index block sits behind a cache
  breakpoint; dynamic recalled candidates ride near the newest turn; memory
  edits are batched so they don't thrash the cache.
- Candidate ranking (when the store outgrows full injection): relevance
  dominant; boosts for exact title/tag matches and pinned status; mild recency
  for mutable state; duplicates removed but conflicting facts never silently
  deduplicated.

Model-facing tools (normal chat registry): add memory, supersede memory,
create collection, search, open collection. The tool surface is identical for
both access levels — a write targeting an "asks first" collection is routed
into the inline-proposal flow automatically instead of applying directly.

## Writes and disclosure

**Proactive-but-disclosed by default.** Per-write approval fatigue would kill
a capture feature, so approval is opt-in per collection (the "asks first"
level) rather than global; everywhere else every AI write is visible and
instantly reversible:

- Writes to "AI writes freely" collections show a conversation chip —
  "Memory added to *Travel preferences*" — with **View** and **Undo**
  (one tap).
- Writes to "AI asks first" collections surface as an inline proposal card
  (**Accept / Edit / Dismiss**) and apply only on acceptance.
- Every entry permanently records who added it and from which conversation.
- A compact **activity feed** covers additions, edits, supersessions, moves,
  deletes, and access changes.
- Confirmation is additionally required for: bulk changes, destructive
  operations, sensitive categories, and switching a collection from
  "asks first" to "writes freely".

The invariant: **no memory ever exists that the user didn't watch being
created or explicitly accept.**

## Background review integration

Review services (`*ReviewService` fresh-context runs) are memory *consumers
and proposers*, never direct writers:

- **Read recipe**: pinned global collections + collections scoped to the
  service's feature. Nothing else. This is the payoff of scoping — e.g. "don't
  flag mail from X, I always delete it" rides into every email review run for
  a few dozen tokens.
- **`propose_memory`** (scoped, system-only tool — not on
  `ToolRegistry.shared`): when the run notices a memory-worthy pattern, it
  proposes a finished artifact — exact entry text, target collection or
  new-collection request, scope, tags — following the existing proposal-tool
  convention (durable proposed state + review card, never direct application).
  The review card renders it with **Accept / Edit / Dismiss**; accepting is
  one tap and zero extra inference.
- **Restraint is prompt- and cap-enforced**: hard cap of 1–2 proposals per
  run. The injected memories double as dedup — the model sees what already
  exists before proposing.
- **Dismissals are durable** (declined proposal state suppresses
  re-proposing the same observation), same philosophy as
  `lastReviewedAt`/`reviewedCount` suppression in the email loop. "No" must
  not become a weekly question.

## UI outline

A first-class Workspace destination (standard `WorkspaceFeature` /
`WorkspaceItem` / settings wiring).

- **macOS**: three-column navigation — sidebar (All Memory, Recent, Activity,
  Tags, then collections, with pinned collections surfaced), searchable
  entry list, detail column for viewing/editing.
- **iOS**: Memory landing screen (global search, Recent, collections, tag
  shortcuts) → collection screen with local search → entry detail.
- **Collection row anatomy**: title, two or three tag chips, entry count,
  last-changed date, trailing access badge, subtle full-row tint keyed to
  access level; scope chip when feature-scoped.
- **Search**: one global entry point plus in-collection scope, visibly labeled
  ("All Memory" vs. the collection name). Matches titles, entry bodies, tags,
  and provenance; filters for tags, access level, scope, and "Added by AI".
  Recently viewed/changed surfaced before the corpus grows.

## Deliberately excluded from v1 (future extensions)

- Embeddings / semantic search — add when recall testing shows paraphrase
  misses lexical search can't cover.
- Multi-collection entry references — single home + tags until proven
  insufficient.
- Nested collections — hierarchy adds moving/inheritance/permission questions
  before users need them.
- Direct memory writes from background runs — `propose_memory` covers the
  need; revisit only with evidence that valuable observations die in
  proposals.
- Low-confidence proposals in "AI writes freely" collections — the inline
  proposal flow already exists for "asks first" writes, so letting the model
  voluntarily downgrade an uncertain save to a proposal is free to add later;
  in v1 the write path is determined by the collection's access level alone.
- Scheduled consolidation (a MemoryReviewService proposing merges/staleness
  cleanups as reviewable diffs) — the self-healing answer to collection
  sprawl, worth building once real stores exhibit it.

## Resolved at planning (details in `docs/MEMORY_PLAN.md`)

- **Injected store serialization** — deterministic compact Markdown from a
  cached `MemoryPromptBuilder` (pinned first, 8-hex entry handles, superseded
  entries excluded), measured by a new byte÷4 `TokenEstimator`. The app has
  no Anthropic client or `cache_control`; "cache placement" means prefix
  stability, nothing more.
- **Entry-body search** — parallel and minimal: in-memory lexical search via
  the shared `SearchQuery.matches` behind one repository method, not the
  Notes `SearchIndex` (whose queries can't filter by source and ignore
  titles/tags). The repository method is the seam for a future index swap.
- **Proposal records** — own `MemoryProposal` SwiftData model copying the
  `NoteEditProposal` pattern (statuses, `cardPostedAt` drain), not the
  vault-shaped type; one record serves asks-first chat writes and
  `propose_memory`. New `ReviewType` cases plus `edit`/`undo` action tokens.
- **Chip-undo** — hard delete, no tombstone; `MemoryActivityEvent` snapshots
  entry text on every mutation, so the activity feed is the audit trail.
  Undo stays enabled only while the entry is unmodified and unsuperseded.
