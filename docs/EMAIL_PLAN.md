# SwiftClaw Email Feature — Plan & Status

The email feature is **code-complete** and green on `swift build`, `swift test`
(104 tests, 19 suites), and `xcodebuild -scheme SwiftClaw -destination
'platform=macOS' build`. What remains is live end-to-end verification against a
real account and a short list of explicitly-deferred scope items (§ Next work).

This doc is the design reference: locked decisions, conventions to follow, what
ships today, and what's deferred. Implementation history lives in git.

## Locked decisions

| Area | Decision |
|---|---|
| Mail library | **SwiftMail (Cocoanetics)** — IMAP + SMTP, built on `swift-nio-imap`. |
| Auth | **App-specific password in Keychain**, per-account keys under `EmailAccountKeychainKeys.imapPassword(for:)` / `.smtpPassword(for:)`. OAuth2 is out of scope. |
| Sync | **Pluggable `MailSyncScheduler`** — foreground `Task`+`Task.sleep` loop (always on) + `#if os(macOS)` `NSBackgroundActivityScheduler`. Syncs INBOX plus resolved Sent/Trash folders; iOS `BGTaskScheduler` impl deferred to Phase 0.5. |
| Multi-account | First-class. Accounts in `EmailAccountStore`; each `Email` tagged with `accountID`; sync/reply/review-dispatch resolve the per-email account at call time. |
| Email body store | Inline on the `Email` SwiftData entity; attachments on disk via `EmailAttachmentStore` (mirrors `ImageAttachmentStore`). |
| Threading | `EmailThread` entity; `ThreadResolver` clusters by RFC-822 `References`/`In-Reply-To` + normalized subject. Identity-stable across re-syncs. Threads span accounts. |
| Review → chat | AI tool `notify_user_about_emails(...)` — the model only calls it when action is needed, so "no action → no chat → no notification" falls out naturally. Runs from a one-off `ToolRegistry`, never `ToolRegistry.shared`. |
| Review-chat representation | Generalized `reviewCardData: Data?` on `ChatMessage` encoding `ReviewCardPayload { reviewType, items }`. New review types (Cal/Reminders) add a `ReviewType` case + renderer + dispatcher — **no SwiftData model change**. |
| Reply UX | SMTP composer (To/Cc/Subject/Body) with full quoting + threading headers from `EmailView`; review-card Reply flags the email for follow-up. No AI drafting in MVP. |
| Destructive UX | Two-click confirmation on archive/delete (mirrors `ChatHistoryActionButton`). Delete is a recoverable move-to-Trash; irreversible expunge is a separate "Delete Permanently" affordance in Trash. |

## Conventions to follow

- **`EmailRepository` is the single mutation boundary** for all Email/SwiftData
  writes (the first repo abstraction in the codebase). Views read via `@Query`;
  sync/flags/threading/review-selection write through the repo. New repositories
  get called out in `AGENTS.md`.
- **Singletons** are either `@MainActor @Observable final class` with `static
  let shared` (UI-facing: `MailSyncMonitor`, `EmailAccountStore`) or `actor`
  (rate gates). SwiftData mutations stay MainActor-isolated.
- **Errors**: `LocalizedError` enums with `errorDescription` (`MailClientError`).
- **Logging**: `os.Logger`, `category: "mail.*"`. Error payloads and account
  identity use default privacy (can echo hostnames/usernames); non-sensitive
  values (mailbox names, counts) stay `.public`.
- **Sendable**: Swift 6 strict concurrency — annotate all new domain types.
- **Cross-platform**: `#if os(macOS)` guards throughout; Email code is written
  iOS-clean even though only macOS builds today.
- **Previews**: guard MailClient/Inference entry points with
  `ProcessInfo.processInfo.isRunningInPreview`.

## What ships today

**Data & sync**
- `Email` / `EmailThread` / `EmailNote` / `EmailAttachment` SwiftData models +
  `ChatMessage.reviewCardData`. Additive lightweight migration.
- `MailClient` protocol + `SwiftMailClient` (IMAP+SMTP) + `MockMailClient`.
- `EmailRepository`: upsert, flag/archive/delete, identity-stable incremental
  `resolveThreads()`, note authoring, review selection, sent-message ingest,
  server-side deletion + flag reconciliation (`fetchMailboxUIDSet` cheap scan).
- Incremental high-water-UID fetch with UIDVALIDITY-change full re-fetch.
- Multi-mailbox sync (INBOX + resolved Sent/Trash); synthetic Sent rows and
  moved-to-Trash rows reconcile to real server UIDs by Message-ID.
- `MailSyncScheduler` (foreground loop + macOS background activity) +
  `MailSyncWorker` + `MailSyncMonitor` status surface.

**Review pipeline**
- `EmailReviewService` (own interval, batch-capped at 40 threads/pass, stamps
  `lastReviewedAt` only after a successful inference pass) + `EmailReviewNotifyTool`.
- `ReviewCardPayload` rendering via `ReviewCardRendererRegistry` +
  `EmailReviewCardRenderer`; `EmailReviewActionDispatcher` routes actions
  through the repo + per-account `MailClient`. Acted-upon items drop off the
  card; Reply marks read + flagged so it surfaces in the Flagged mailbox.

**UI**
- `EmailView`: mailbox sidebar (Inbox/Flagged/Archive/Trash, dead mailboxes
  hidden when empty) + thread list + detail. Mark-read on view, two-click
  archive/delete, Delete-Permanently in Trash, reply composer with quoting,
  note editor, attachment list with QuickLook, WKWebView HTML rendering.
- Sync Now / Review Now toolbar buttons (with spinner + disabled state),
  dock badge, optional auto-navigate to the review chat.
- Review-card row tap → navigates to the email; action-badge tap → confirm →
  dispatch.
- `EmailSettingsView`: account list + add/edit sheet with Test Connection.

## Next work

1. **Live end-to-end verification (highest priority — in progress, on the
   user's end).** The only remaining workstream outside the codebase. Walk the
   full loop against a real server and capture anything that only breaks live
   (header parsing, charset/HTML edge cases, folder-name quoting):
   - Test Connection succeeds; account persists; passwords land in Keychain.
   - First sync pulls INBOX; threads cluster sensibly; incremental sync fetches
     only new mail; UIDVALIDITY change triggers a full re-fetch.
   - Special-use folders resolve per provider; archive / delete-to-Trash / flag
     / mark-read all reflect on the server.
   - Trash sync promotes moved rows to the server's Trash UID; Delete
     Permanently then expunges the Trash copy and removes the local row.
   - Reply sends, threads on the recipient side, APPENDs to Sent, and the local
     synthetic row reconciles to the real UID on the next Sent sync.
   - A review pass produces a review chat; acting on a card item removes it and
     dispatches to the right server call.

   **Next code step once live testing surfaces nothing blocking: cap the
   first-sync fetch** (see deferred item below). It's promoted from "defer until
   observed" to the top of the queue because live testing now runs against a
   real mailbox, where an unbounded full-body + attachment pull on first sync is
   the single most likely thing to actually hurt (slow/janky first sync, disk
   churn). Fetch most-recent-N (or a date window) on the first pass, then let
   the incremental high-water path take over.

2. **Explicitly deferred (out-of-scope, not active work):**
   - **Phase 0.5 / iOS target** — `.iOS(...)` in `Package.swift`, `#if os(iOS)`
     audit, `BGTaskSchedulerPermittedIdentifiers` in Info.plist, and a
     `BGTaskMailSyncScheduler`. Until then iOS falls back to the foreground loop.
   - **`@Query` windowing in `EmailView`** — not actionable via the `@Query`
     macro; would need `FetchDescriptor` paging. Fine for typical mailboxes.
   - **Per-op connection reuse** — each archive/delete/flag/send op does a fresh
     connect→login→op→disconnect. SwiftMail's per-op lifetime is fine for the
     MVP poll cadence; revisit if a provider rate-limits.
   - **First-sync fetch is unbounded** (full body + attachments for every INBOX
     message). If a large mailbox makes first sync slow during live testing,
     cap the initial fetch — but defer until that's actually observed.
   - **Archive mailbox sync** — archive actions move server mail to the
     provider's Archive/All Mail folder and hide the row locally. Pulling the
     Archive mailbox as a first-class synced mailbox is deferred.

3. **Known by-design behaviors (not bugs):**
   - Optimistic local flag/read mutations can be briefly reverted by
     `reconcileFlagsFromSnapshot` if a sync races the action's server
     round-trip. Self-heals on the next sync; the window is a fraction of the
     300 s poll. Gating it would add bookkeeping for a non-bug.
   - `ThreadResolver` subject clustering is case-sensitive. Revisit only if
     users report mis-threading.
