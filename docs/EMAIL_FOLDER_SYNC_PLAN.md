# IMAP Folder Sync + Folder-Aware Inbox Review

> **Status: implemented.** User-approved plan (2026-07-04); implemented in the
> app, review flow, settings UI, tests, and email docs.

## Context

SwiftClaw currently syncs only INBOX plus the account's resolved special-use
Sent/Trash/Archive folders (`MailSyncWorker.mailboxesToSync`,
`SwiftClaw/Services/Email/Sync/MailSyncWorker.swift:176`). The user's live
account has additional folders (custom/filter-rule folders, Spam, Drafts) that
never appear in the app. This work makes folder sync complete — LIST all
folders, sync them incrementally, surface them in the Email sidebar — and
integrates folders into the AI Inbox Review without token blowup or card
overload.

**Decisions already made with the user (do not re-litigate):**

1. **Custom folders in scheduled review: user-configurable per account, per
   folder.** A Settings surface (Apple HIG-clean, `.formStyle(.grouped)`) lets
   the user toggle which folders are included in scheduled review passes. The
   existing qualification flags (read/unread/flagged/notated) then govern what
   qualifies within an included folder. Default: custom folders **excluded**
   (no surprise token cost on ship; inclusion is one toggle away). INBOX is
   always included.
2. **Spam/Junk: sync it, show it, but never include in scheduled review.**
   Reachable on request only — the review model gets a `folders` filter on
   `fetch_inbox_emails` so "anything real in my spam?" works conversationally.
3. **Drafts: sync read-only + sidebar entries for both Sent and Drafts.**
   Drafts are viewable, not editable (composing still goes through the reply
   composer). Sent and Drafts are excluded from review candidacy (Sent messages
   keep their current role as thread *context*).

Read these before starting: `docs/features/EMAIL.md`, `docs/EMAIL_PLAN.md`,
`docs/conventions/MODELS.md`, `docs/conventions/SETTINGS.md`, `AGENTS.md`.

## Current architecture map (verified against source)

| Concern | Where |
|---|---|
| Mail client protocol + domain types (`FetchedMessage`, `MailboxFetchResult`, `MailboxUIDSet`) | `SwiftClaw/Services/Email/MailClient/MailClient.swift` |
| Real IMAP client; `resolveSpecialUseMailboxes()` caches sent/trash/archive names onto the account | `SwiftClaw/Services/Email/MailClient/SwiftMailClient.swift:337` |
| Test double | `SwiftClaw/Services/Email/MailClient/MockMailClient.swift` |
| Sync loop; `mailboxesToSync`, `SyncedMailbox`, UIDVALIDITY handling, Nth-pass reconcile | `SwiftClaw/Services/Email/Sync/MailSyncWorker.swift` |
| Per-(accountID, mailbox) high-water store — **needs no changes** | `SwiftClaw/Services/Email/Sync/MailboxSyncStateStore.swift` |
| Upsert/threading/flag mutations | `SwiftClaw/Services/Email/Repository/EmailRepository.swift` (`upsertMessages` at :29, `insert` at ~:700) |
| Review selection pipeline + decay suppression | `SwiftClaw/Services/Email/Repository/EmailReviewSelection.swift` |
| Review service + system prompt | `SwiftClaw/Services/Email/Review/EmailReviewService.swift` |
| Model-facing fetch tool + filter | `SwiftClaw/Services/Email/Review/EmailReviewFetchTool.swift`, `EmailReviewFetchFilter.swift` |
| Thread JSON payload sent to the model | `SwiftClaw/Services/Email/Review/EmailReviewDescriptors.swift` |
| SwiftData models (`Email.mailbox: String`, `isArchived`/`isDeleted` flags; `EmailThread.reviewableMessages`) | `SwiftClaw/Models/Email.swift` |
| Account persistence (additive-Codable-field pattern) | `SwiftClaw/Services/Email/Accounts/EmailAccountStore.swift` |
| UI partitions (inbox/archive/trash by flags) | `SwiftClaw/Features/Email/EmailAccountScope.swift:41` (`EmailThreadScopeSnapshot`) |
| Sidebar + `EmailMailbox` enum (inbox/flagged/archive/trash) + `mailbox(for:)` | `SwiftClaw/Features/Email/EmailView.swift:471`, `:299` |
| Settings keys + email settings UI | `SwiftClaw/Settings/AppSettings.swift:151-164`, `SwiftClaw/Settings/EmailSettingsView.swift` |

SwiftMail library facts (pinned rev `3bfb4a3a…`, checked in DerivedData
checkout):

- `IMAPServer.listMailboxes(wildcard: "*") async throws -> [Mailbox.Info]`
  (`Sources/SwiftMail/IMAP/IMAPServer+Namespace.swift:32`).
- `Mailbox.Info` = `name`, `attributes` (OptionSet: `.noSelect`,
  `.hasChildren`, `.marked`, and special-use `.archive/.drafts/.flagged/.junk/
  .sent/.trash/.inbox`), `hierarchyDelimiter`, `isSelectable`.
- **`\All` is NOT mapped** by SwiftMail's `specialUseTokens` — Gmail's
  `[Gmail]/All Mail` arrives with *no* special-use attribute and would look
  like a plain custom folder. See skip rules below.

## Implementation

### Phase 1 — Folder catalog: list, classify, persist

New domain types in `MailClient.swift` (nonisolated, `Codable, Sendable,
Hashable` per MODELS.md):

```swift
enum MailFolderRole: String, Codable, Sendable { case inbox, sent, drafts, trash, archive, junk, custom }
struct MailFolderDescriptor: Codable, Sendable, Hashable {
    let name: String          // full IMAP path, e.g. "Work/Receipts"
    let role: MailFolderRole
    let delimiter: String?
}
```

- Add `func listFolders() async throws -> [MailFolderDescriptor]` to the
  `MailClient` protocol. Implement in `SwiftMailClient` (connect → login →
  `server.listMailboxes()` → map → disconnect; same connection lifecycle as
  `resolveSpecialUseMailboxes`). Implement in `MockMailClient` with an
  injectable catalog.
- Mapping/skip rules (implement as a pure static
  `SwiftMailClient.classify(_ infos:) -> [MailFolderDescriptor]` so it's unit
  testable without a server):
  - Skip `.noSelect` folders (containers).
  - Skip `.flagged` folders (virtual, e.g. Gmail Starred).
  - `INBOX` matched case-insensitively → `.inbox` (RFC 3501: INBOX is
    case-insensitive); dedupe so exactly one inbox survives.
  - Special-use attributes → matching roles.
  - **Gmail guard:** any folder whose path starts with `[Gmail]` or
    `[Google Mail]` + delimiter that classified as `.custom` is skipped. This
    excludes All Mail (`\All` unmapped, unbounded), Important, etc., while
    Gmail user labels (top-level, outside the namespace) survive as custom.
  - Everything else → `.custom`.
- Persist on `StoredEmailAccount` (additive Codable fields, same pattern as
  `archiveMailbox`): `var folders: [MailFolderDescriptor]?` plus cached
  `draftsMailbox: String?` and `junkMailbox: String?` (symmetry with
  sent/trash/archive; filled from the catalog). Persist via
  `EmailAccountStore.shared.update(...)` from the client, mirroring
  `resolveSpecialUseMailboxes`'s write-back at `SwiftMailClient.swift:374`.

### Phase 2 — Sync every folder

`MailSyncWorker` changes:

- `SyncedMailbox` gains `let role: MailFolderRole` (keep
  `isDeletedMailbox`/`isArchiveMailbox` derivable: `role == .trash` /
  `role == .archive`; simplest is to replace the two Bools with `role` and
  update call sites).
- `mailboxesToSync(for:client:)` rebuild:
  - If `account.folders == nil` → call `client.listFolders()` once
    (best-effort; on throw fall back to today's INBOX+sent+trash+archive list
    so sync never regresses).
  - Otherwise use the cached catalog; **refresh the catalog on reconcile
    passes** (the existing `shouldReconcile` Nth-pass cadence — thread it into
    `syncAccount`) so new/renamed server folders appear within ~4 sync
    intervals.
  - Sync set = catalog minus nothing (all roles sync), preserving the existing
    Gmail-archive exclusion semantics: the archive entry still only syncs when
    the server advertised a real `\Archive` (which the catalog guarantees,
    since `\All` never classifies as archive).
- Keep `firstSyncMaxMessages = 500` per mailbox (per-mailbox cap already
  bounds first-sync cost; `MailboxSyncStateStore` needs zero changes).
- `upsert(...)` and `EmailRepository.upsertMessages(...)` gain the role
  (replace the two Bools with `role: MailFolderRole`, mapping internally:
  `isDeleted = role == .trash`, `isArchived = role == .archive`); `insert`
  writes `email.folderRole = role.rawValue`.
- **Drafts UID churn:** editing a draft deletes + re-APPENDs it (new UID).
  Reconcile the drafts mailbox on **every** pass (not Nth) and extend
  `EmailRepository.reconcileDeletions(...)` with `hardDelete: Bool = false`;
  drafts pass `true` so stale draft rows are removed outright instead of
  landing in Trash as soft-deletes.
- Junk syncs normally (bodies) — cost is bounded by the 500 cap and the
  incremental high-water afterward.

### Phase 3 — `Email.folderRole` + backfill

- Add `var folderRole: String = "inbox"` to `Email` (defaulted ⇒ no schema
  bump, matching `needsFlagSync` precedent at `Email.swift:158`). Add a
  computed `var role: MailFolderRole` accessor (raw-string + accessor per
  MODELS.md).
- One-shot backfill (existing stores have Sent-folder rows whose
  `mailbox == account.sentMailbox` but `folderRole == "inbox"`): add
  `EmailRepository.backfillFolderRolesIfNeeded(accounts:)` guarded by a
  UserDefaults flag; map `mailbox` against each account's cached
  sent/trash/archive names → role, else `inbox`. Call it where app startup
  already wires email (locate with `rg -n "migrateLegacyIfNeeded\("` — call
  the backfill right after it).
- `EmailThread.reviewableMessages` (`Email.swift:55`) becomes:
  `!isArchived && !isDeleted && role != .junk && role != .drafts` — junk and
  drafts never drive review timing/eligibility; Sent stays reviewable
  (existing behavior: it's the thread context and "already replied" signal).

### Phase 4 — UI: dynamic folders

- `EmailMailbox` (`EmailView.swift:471`) becomes an enum **with associated
  value**: `inbox, flagged, sent, drafts, junk, archive, trash,
  custom(String)`. Keep `Identifiable`/`Hashable`; `id`/title/systemImage
  computed (`sent = paperplane`, `drafts = doc.text`, `junk = xmark.bin`,
  `custom = folder`). Drop `CaseIterable` (sidebar builds its list
  explicitly). Compact-mode `openCompactThread` already passes `EmailMailbox`
  through — updating the enum covers it.
- `EmailThreadScopeSnapshot` (`EmailAccountScope.swift:41`) partitions become
  role-aware:
  - `inbox`: `!isArchived && !isDeleted && (role == .inbox || role == .sent)`
    — **deliberately keeps Sent messages in the inbox partition** so
    replied-to threads keep appearing exactly as today (regression guard:
    `EmailAccountScopeTests`).
  - `sent`: `role == .sent && !isDeleted`; `drafts`: `role == .drafts &&
    !isDeleted`; `junk`: `role == .junk && !isDeleted`.
  - `custom(name)`: `role == .custom && mailbox == name && !isArchived &&
    !isDeleted`.
  - `archive`/`trash` unchanged. Add `customFolderNames` (sorted, present in
    scope) for the sidebar.
- Sidebar (`EmailView.swift` `visibleMailboxes` at :58 and
  `EmailMailboxSidebar`): after Inbox/Flagged, show Sent/Drafts/Junk when
  non-empty (same hide-empty pattern as Archive/Trash today), then a
  "Folders" group listing `customFolderNames`. On macOS the `List(selection:)`
  + `Label` pattern extends directly.
- `mailbox(for:)` (`EmailView.swift:299`) and `quickActionTarget`
  (`:312`) gain the new cases (drafts/junk/sent quick-action target = latest
  message of that role; reply quick-action should be disabled for drafts).
- Thread detail: no changes required — drafts render as normal messages.
  (Read-only by decision; no draft editor.)

### Phase 5 — Review integration

- **Per-account inclusion config:** add
  `var reviewIncludedMailboxes: [String]?` to `StoredEmailAccount` (additive
  Codable; names of **custom** folders opted into scheduled review; `nil` ⇒
  none). INBOX is implicitly always included. Junk/Sent/Drafts/Trash/Archive
  are not configurable (decisions #2/#3).
- `EmailReviewFetchFilter` gains `var folders: [String]? = nil` (explicit
  folder names, case-insensitive compare; when set, those folders' messages
  are candidates regardless of the inclusion config — this is the
  "spam on request" path).
- `EmailReviewSelection`:
  - `fetchReviewCandidateThreads` + `consideredMessages` + the keep logic in
    `fetchThreadsForReview`: a message counts toward review iff
    `role ∈ {inbox, sent}`, **or** (`role == .custom` and its `mailbox` is in
    the account's `reviewIncludedMailboxes`), **or** its `mailbox` matches
    `filter.folders`. Junk/drafts qualify only via `filter.folders`.
    The repository needs the per-account inclusion sets — pass a
    `[UUID: Set<String>]` built from `EmailAccountStore` into the filter (add
    `includedCustomFoldersByAccount` to `EmailReviewFetchFilter`; the tool and
    the `hasThreadsEligibleForReview` gate both populate it) so the repository
    stays free of `EmailAccountStore.shared` reads (testability).
  - `hasThreadsEligibleForReview` must mirror the same message-eligibility
    rule, or the scheduled loop will burn/skip passes inconsistently.
- `EmailReviewFetchTool`: add a `folders` array parameter (type `.string`
  array — check `ToolParameter` for array support; if absent, accept a
  comma-separated string and split). Document in the tool description that
  omitted ⇒ configured defaults, and that Junk/custom folders are reachable by
  name.
- `EmailReviewDescriptors`: add a `folder` field to the per-message descriptor
  so the model sees where each message lives (one short string per message).
- `EmailReviewService.systemPrompt`: add one short paragraph built from the
  accounts' catalogs, e.g.
  `Folders in scheduled review: INBOX, Work/Receipts. Available on request via
  fetch_inbox_emails {"folders": [...]}: Newsletters (12 unread), Junk (4
  unread), Sent, Drafts, Archive, Trash.` Unread counts per folder come from a
  cheap `fetchCount` per folder name (`FetchDescriptor<Email>` on
  `mailbox == name && !isRead`). Keep it to ~1–2 lines per account — this is
  the token-efficiency contract: awareness is a digest, bodies are pulled only
  when the model opts in.

### Phase 6 — Settings UI (HIG)

- `EmailSettingsView`: new `Section("Review Folders")` in the review area.
  One row per configured account (skip the per-account row chrome when only
  one account): `NavigationLink(account.effectiveDisplayName)` →
  `EmailReviewFolderSettingsView(account:)`.
- `EmailReviewFolderSettingsView` (new file under `SwiftClaw/Settings/`):
  `Form` + `.formStyle(.grouped)` (repo convention, AGENTS.md §Adding a
  feature):
  - Section 1 "Always reviewed": an `Inbox` row with a disabled, on toggle
    (communicates the invariant without letting it break).
  - Section 2 "Your folders": one `Toggle(folder.name)` per `.custom` folder
    from `account.folders`, bound to membership in
    `reviewIncludedMailboxes`; footer text: *"Included folders join the
    scheduled email review. The review's read/unread/flagged filters still
    apply. Spam, Sent, Drafts, Trash, and Archive are never reviewed
    automatically — ask in chat to check them."*
  - Toolbar/footer `Button("Refresh Folder List")` → `client.listFolders()`
    with a `ProgressView` while running (folder list may be empty until first
    sync). Guard with `isRunningInPreview`.
  - Persist through `EmailAccountStore.shared.update(...)`.
- No new `SettingsKeys` needed (config lives on the account JSON), but check
  `docs/conventions/SETTINGS.md` for the account-persistence notes.

### Phase 7 — Tests (Swift Testing, existing suites)

- `SwiftMailClientTests`: `classify(_:)` mapping — special-use roles, noSelect
  skip, `.flagged` skip, Gmail namespace skip (All Mail/Important skipped,
  top-level label kept), INBOX case-insensitivity.
- `MailSyncWorkerIncrementalTests`: multi-folder iteration from a mock
  catalog; catalog-fetch fallback when `listFolders` throws; catalog refresh
  on reconcile passes; role → `folderRole` propagation.
- `MailSyncWorkerDeletionReconciliationTests`: drafts hard-delete on UID
  churn (old UID gone ⇒ row removed, not trashed); junk/custom soft-delete
  unchanged.
- `EmailRepositoryTests`: upsert writes `folderRole`; backfill maps
  sent/trash/archive rows and is idempotent.
- `EmailAccountStoreTests`: new Codable fields round-trip + decode of legacy
  JSON without them.
- `EmailAccountScopeTests`: new partitions; **regression: sent messages still
  appear in the inbox partition**; custom partition scoping by name+account.
- `EmailReviewFetchTests` / `EmailReviewServiceTests`: excluded custom folder
  contributes nothing; included folder's threads flow; `folders` filter
  reaches junk; `hasThreadsEligibleForReview` agrees with the fetch path
  (e.g. unread mail only in an excluded folder ⇒ gate says false).

### Phase 8 — Docs

- Update `docs/features/EMAIL.md` (Folders + Incremental sync + Known
  limitation sections — the "INBOX only" reconciliation note is now stale) and
  `docs/EMAIL_PLAN.md` status/scope.

## Edge cases & accepted limitations (state these in EMAIL.md)

- **Folder rename on the server** = new folder in the catalog; the old name's
  rows linger until their mailbox 404s on reconcile (logged, non-fatal).
  Accepted for now — removing rows for a vanished folder risks data loss on
  transient LIST hiccups.
- **Hierarchical folders** render flat with their full path ("Work/Receipts").
- Messages the user moves between folders in *other* clients surface via the
  existing deletion-reconcile + new-folder-upsert (Message-ID dedup does not
  span folders except the archive-reclaim path — a cross-folder move can
  transiently show the message in Trash until the destination folder syncs on
  the same pass; same behavior Archive had before its reclaim path, accepted).
- Per-mailbox syncs within an account stay **sequential** (one IMAP
  connection); accounts stay concurrent. More folders ⇒ longer per-account
  pass; acceptable, each folder is one round-trip when idle.

## Verification

1. `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build -derivedDataPath /tmp/DerivedData | xcbeautify --quiet`
2. Targeted suites first (`-only-testing:SwiftClawTests/<Suite>` for each suite
   in Phase 7), then the full test pass.
3. **Live run** (user has a real account configured): launch the app (`/run`
   skill), let a sync pass complete, and verify — sidebar shows Sent/Drafts/
   Junk + the account's custom folders with plausible contents; a custom
   folder's threads open correctly; Settings → Email → Review Folders lists
   the real folders; toggling one on and pressing "Review Now" pulls from it
   (check `mail.review.fetch` logs via Console/`log stream --predicate
   'subsystem CONTAINS "SwiftClaw"'`); with everything off, scheduled review
   behavior matches today's INBOX-only run.
4. Confirm no regression: an existing thread with a reply still shows in
   Inbox; deleting/archiving from the app still round-trips.
