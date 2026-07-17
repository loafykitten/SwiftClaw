# SwiftClaw Memory — Implementation Plan

## Context

`docs/features/MEMORY.md` is the settled design: persistent, user-visible
assistant memory as named **collections** of small **entries**, with
per-collection access levels ("AI asks first" / "AI writes freely"), optional
per-feature **scope**, **pinned** collections, an **Inbox** for uncertain
classification, tiered LLM exposure by measured store size, chip+undo
disclosure for autonomous writes, inline proposal cards for gated writes, and
`propose_memory` for background review runs. Governing priority: **a missed
relevant memory is worse than spent tokens** — over-include everywhere.

This plan is the implementation research and phase breakdown. Research was
run against the current codebase (2026-07-16); every load-bearing claim below
was verified against source.

**Platform facts that shaped the plan:**

- All inference providers are OpenAI-compatible
  (`Services/Inference/Providers/`). There is **no Anthropic client, no
  `cache_control`, and no tokenizer** anywhere in the app. The design doc's
  "prompt-cache placement" therefore means *deterministic serialization and
  prefix stability*, not explicit breakpoints.
- `.prependPersona` hoists **all** system messages into one combined first
  system message (`InferenceService.messagesByApplyingSystemPromptMode`).
  The injected memory block lands there. Transient per-turn system
  injections (investigation hint, email-review context in
  `ChatCompletionService`) already accept this; tier-2 recall injection
  follows the same precedent.
- `WorkspaceItem.memory`, its brain icon, and a "Coming soon" `MemoryView`
  placeholder **already exist** (`Features/Workspace/WorkspaceView.swift`,
  `Features/Memory/MemoryView.swift`). The item is always visible because its
  `feature` mapping returns nil. Implementation converts this wiring; it does
  not add a second item.
- `SearchIndex` (`Services/Search/`) is structurally source-agnostic, but its
  FTS/vector queries have **no source-type filter** and FTS indexes only
  chunk bodies — not titles or tags (tags live in the separate
  `NoteLinkGraph` DB). Sharing the Notes database would mix results and miss
  Memory's title/tag search requirement.
- Review-card machinery is reusable as designed: `ReviewCardPayload` JSON on
  `ChatMessage.reviewCardData`, `ReviewType` with forward-compat `.unknown`,
  generic `approve`/`reject` tokens, renderer registry + per-type dispatchers
  (`Features/Chats/ReviewCards/`). **No `edit` or `undo` action token exists
  yet**; both must be added.
- Email review suppression (`EmailReviewSelection`) is *time-decayed
  resurfacing* (1 + reviewedCount days, capped at 7), deliberately not
  permanent. Memory dismissals need their own durable record — rejected
  proposals fill that role.
- The pure-SwiftData repository precedent is `EmailRepository` (`@MainActor`
  class over a `ModelContext` as the mutation boundary). None of Notes'
  vault/actor/lease machinery applies to a SwiftData-only feature.
- Soft-delete precedent: `Email.isDeleted` (exists because IMAP Trash is real
  remote state). Notes protects with pre-mutation snapshots instead —
  the pattern Memory adopts via its activity feed.

## Key decisions (resolves the feature doc's open questions)

| Decision | Pick | Why |
|---|---|---|
| Injected store serialization | Deterministic compact Markdown built by a cached `MemoryPromptBuilder`: pinned collections first, then by collection `createdAt`; entries as `- (8-hex-handle) fact [date]`; superseded entries excluded; access level + scope + tags in each collection header | Determinism + mutation-batched cache = stable prompt prefix, the only "caching" OpenAI-compatible providers offer. 8-char UUID prefixes (repository resolves, errors on ambiguity) because full UUIDs cost ~20 tokens against 15–40-token facts |
| Token measurement | New `TokenEstimator` in `Shared/` — UTF-8 bytes ÷ 4, conservative | Nothing in the app counts tokens; existing caps are character-based (`ReadNoteTool` 8k chars). ~200 entries ≈ 4–8k estimated tokens, matching the doc's expectation; the ≤~40k full-injection tier is the shipped common case |
| Entry-body search | Parallel and minimal: in-memory lexical search over the SwiftData store via the shared `SearchQuery.matches` (`Shared/SearchQuery.swift`), behind one `MemoryRepository.search(_:)` used by both the UI and the `search_memory` tool. **Not** `SearchIndex` | Corpus is hundreds of ~25-token entries; embeddings are explicitly deferred. `SearchIndex` can't filter by source, ignores titles/tags, and would add a second SQLite cache + indexer for zero recall gain. `SearchQuery` already serves Chats and Email. The repository method is the seam for a future `SearchIndex`-backed swap (own DB under `App Support/SwiftClaw/Memory/Index/`, `source_type: "memory"`) if observed paraphrase misses justify it |
| Proposal records | New `MemoryProposal` SwiftData model in the main store, copying the `NoteEditProposal` **pattern** (statuses, `chatID`, `cardPostedAt` + coordinator drain), not the type. One record type serves both asks-first chat writes and background `propose_memory` | Notes' record is vault-shaped (paths, base hashes, vault IDs — meaningless here). No `conflicted` status: memory has no base-hash race; a proposal whose target collection vanished routes to Inbox instead ("never force-file") |
| Proposal card actions | Accept / Edit / Dismiss via new `ReviewType.memoryProposal`, reusing `approve`/`reject` tokens plus a new `edit` token; Edit opens a prefilled sheet, saving = accept-with-modified-text; Dismiss = durable `.rejected` | `ReviewItem.action` already decodes unknown tokens to nil, so adding cases is forward-safe |
| Chip-undo semantics | **Hard delete**, no tombstone. `MemoryActivityEvent` snapshots entry text on every mutation, so the feed is the audit trail (and a cheap future "restore from activity"). Undo enabled only while the entry is unmodified (`updatedAt == createdAt`) and not superseded; afterwards the chip keeps View, disables Undo | Undo means *the write never happened*; a tombstone recreates the clutter the user just rejected. Matches the app's snapshot-not-tombstone pattern (Notes revisions) |
| Background dismissal dedup | Rejected `MemoryProposal` rows persist; each review run's memory context includes recent rejected proposal texts for that scope ("previously declined — do not re-propose") | The injected text *is* the dedup, per the design doc; no fingerprint machinery |
| Store placement | All four new models in the **main** local store (both `mainSchema` and `fullSchema` lists in `SwiftClawModelContainerFactory` — main-only registration requires both) | Device-local like `NoteEditProposal`; additive models ride lightweight migration |

## Data model (`Models/`, per `docs/conventions/MODELS.md`)

All `@Model final class` with `@Attribute(.unique) var id: UUID`, raw-string
enums + computed accessors, JSON blobs on `Data?`:

- **`MemoryCollection`** — `title`, `details: String?`, `tagsData: Data?`,
  `accessLevelRawValue` (`asksFirst` / `writesFreely`), `scopeRawValue:
  String?` (nil = global, else a `WorkspaceFeature` rawValue), `isPinned`,
  `isInbox` (built-in Inbox: created lazily by the repository, undeletable,
  unscopable), `createdByRawValue` (user / ai), `createdAt`, `updatedAt`.
  `@Relationship(deleteRule: .cascade, inverse: \MemoryEntry.collection)
  var entries`.
- **`MemoryEntry`** — `body`, `tagsData: Data?`, `createdByRawValue`,
  `sourceChatID: UUID?`, `supersededByID: UUID?`, `createdAt`, `updatedAt`,
  `collection` inverse. Supersession adds a replacement entry and stamps the
  old one — never in-place rewrites of established facts.
- **`MemoryProposal`** — `entryText`, `targetCollectionID: UUID?`,
  `newCollectionTitle: String?` (+ requested access level raw value),
  `scopeRawValue: String?`, `tagsData: Data?`, `summary`, `statusRawValue`
  (`pending/applying/applied/rejected/expired`), `sourceRawValue` (chat vs.
  which review service), `chatID: UUID?`, `createdAt`, `resolvedAt: Date?`,
  `cardPostedAt: Date?`.
- **`MemoryActivityEvent`** — `kindRawValue` (added / edited / superseded /
  movedCollection / deleted / accessChanged / undone / proposalAccepted /
  proposalDismissed), `entryID: UUID?`, `collectionID: UUID?`,
  `snapshotText: String?`, `actorRawValue`, `chatID: UUID?`, `createdAt`.

**`MemoryRepository`** — `@MainActor final class`, the single mutation
boundary (`EmailRepository` precedent). Every mutation writes its
`MemoryActivityEvent` in the same save and invalidates the prompt-builder
cache. Owns Inbox ensure-exists, supersession, handle-prefix resolution,
`search(_:)`, and the serialized-store build + token estimate.

**`MemoryFeatureModel.shared`** — thin `@MainActor @Observable` coordinator
(no I/O in init, per convention), configured with the `ModelContainer` in
`AppBootstrap`; exposes the repository to views and shared-registry tools and
carries the Workspace-tile summary (entry count, last activity, pending
proposals).

## Phase 1 — Models, repository, feature wiring, core UI

1. Models + container registration + `MemoryRepository` +
   `MemoryFeatureModel` + `SwiftClawTests/Memory/` suites (repository
   mutations, activity events, supersession, Inbox, handle resolution,
   search).
2. Feature wiring per the AGENTS.md checklist, **converting the existing
   placeholder**: `WorkspaceFeature.memory` case (five switches in
   `Shared/WorkspaceFeature.swift`); `SettingsKeys.memoryEnabled` +
   `SettingsStorage.isMemoryEnabled` + the `isWorkspaceFeatureEnabled` /
   `defaultWorkspaceFeatureEnabled` switches (`Settings/AppSettings.swift`);
   `ToolsView` `@AppStorage` + `featureBinding` branch;
   `SettingsSection.memory` + `MemorySettingsView`
   (`Settings/SettingsView.swift`, `Settings/Sections/`); `WorkspaceView`:
   give `.memory` its `feature` mapping (ends unconditional visibility) and
   replace the coming-soon tile with a live summary tile (Notes tile
   pattern).
3. Memory UI replacing the `MemoryView` placeholder. macOS three-column:
   sidebar (All Memory, Recent, Activity, Tags, then collections with pinned
   surfaced), searchable entry list, detail column. iOS: landing (global
   search, Recent, collections, tag shortcuts) → collection → entry detail.
   Collection row anatomy per the feature doc — **explicit access badge with
   label + distinct SF Symbol + full VoiceOver string; tint only
   reinforces**. Confirmation dialogs for: asksFirst → writesFreely switch,
   deletes, bulk changes. Search UI over `repository.search` with filters
   (tags, access level, scope, added-by-AI). Activity feed view over
   `MemoryActivityEvent`.

## Phase 2 — LLM exposure in chat

1. `MemoryPromptBuilder` + `TokenEstimator` + tier switch: ≤ ~40k estimated
   tokens → full store block; above → compact index (titles + tags + counts)
   + pinned collections, plus per-turn lexical recall of top candidates from
   the latest user message appended as a transient system message (existing
   transient-injection precedent; ranking: relevance dominant, exact
   title/tag and pinned boosts, mild recency, conflicting facts never
   deduplicated).
2. Injection in `ChatCompletionService` alongside the existing context
   blocks, gated on `isMemoryEnabled`.
3. Tools. Read tools on `ToolRegistry.shared`: `search_memory`,
   `open_memory_collection` (gated by `isConfigured` = feature enabled, with
   a cold-launch `prepareIfNeeded` mirroring
   `NotesFeatureModel.prepareReadToolsIfNeeded`). Write tools request-bound
   at the chat call site with `modelContainer` + `chatID` (`ProposeNote*`
   pattern): `add_memory`, `supersede_memory`, `create_memory_collection`.
   Identical tool surface for both access levels: writesFreely target →
   immediate repository write, tool returns "saved"; asksFirst target →
   insert `MemoryProposal` + queue card, tool returns "proposed — awaiting
   approval". New collections default to writesFreely; an asksFirst creation
   seeds its initial entries inside that same accepted proposal.
4. Disclosure. New `ReviewType.memoryWrite` chip card ("Memory added to
   *X*" — View navigates, Undo per the key decision) and
   `ReviewType.memoryProposal` card (Accept / Edit / Dismiss). New
   `ReviewActionToken` cases `edit` and `undo`. New
   `MemoryCardCoordinator` drains queued chips/cards after the assistant
   reply (`NotesProposalCoordinator` pattern incl. `cardPostedAt`
   crash-safety), invoked next to the Notes drain in
   `ChatCompletionService`. Renderers/dispatchers in
   `Features/Chats/ReviewCards/` + registry and `ChatsView`
   dispatcher-provider branches.
5. Tests: builder determinism + tier switch, prefix resolution, access-level
   routing, undo guard, drain idempotency, tool gating.

## Phase 3 — Background review integration

1. `MemoryReviewContextBuilder.block(for feature:)` — pinned global
   collections + collections scoped to that feature + recent rejected
   proposal texts. Concatenated into each review service's standalone system
   prompt (`NotesReviewService` seam; same for Email / Calendar / Reminders
   services).
2. `ProposeMemoryTool(feature:modelContainer:)` — system-only, added to each
   service's scoped `ToolRegistry(tools:)`, never `ToolRegistry.shared`.
   Hard cap enforced in the tool (rejects calls past 2 per run). Inserts
   `MemoryProposal` with review-service provenance; cards drain into the
   run's review chat (or a dedicated Memory review chat when none exists)
   via the Phase-2 coordinator.
3. Tests: cap enforcement, dismissal-suppression text present, read-recipe
   scoping (pinned + feature only, nothing else).

## Cross-cutting

- Maintain `docs/memory/memory-feature.md` (working-task file) across
  sessions; delete when the feature ships. Evolve `docs/features/MEMORY.md`
  into the standard feature doc with type references as phases land; retire
  this plan into it at the end (Notes precedent).
- Logging: `AppLog`/`os.Logger` category `memory`; entry bodies and titles at
  default privacy (they are personal data).
- Cross-platform: `#if os(...)` only where needed; preview-safe construction
  (no SwiftData/Keychain work in inits).
- Update `docs/testing/USER_FACING_TESTS.md` only at the end-of-feature
  checkpoint.

## Verification

- Per phase:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath
  /tmp/DerivedData CODE_SIGNING_ALLOWED=NO
  -only-testing:SwiftClawTests/<MemorySuite> | xcbeautify --quiet`;
  full macOS + iOS builds at phase end.
- End-to-end after Phase 2: seeded chat run — ask the assistant to remember a
  fact → verify chip, entry, activity event, and undo; flip the collection to
  asksFirst → verify Accept / Edit / Dismiss paths; confirm the injected
  block via the existing system-prompt logging
  (`InferenceService.logFormattedSystemPrompt`).
- Simulator UI passes per `docs/testing/SIMULATOR_UI_VERIFICATION.md`
  (fixture identity, never real data).
