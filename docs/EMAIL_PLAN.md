# SwiftClaw Email Feature — Plan & Status

The email feature is **code-complete**. The remaining active work is live
end-to-end verification against a real account; everything else below is either
the shipped shape or explicitly deferred scope.

Current local verification: `swift test` and
`xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build` pass.

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
- **Logging**: `AppLog.make("mail.*")` (in `Shared/AppLog.swift`) — wraps
  `os.Logger` so Console.app / `log show` are unchanged, and in DEBUG also
  mirrors a clean `HH:mm:ss.SSS  level  category  message` line to stdout.
  Call sites keep the `logger.info("… \(x, privacy: .public) …")` form; the
  rendered message is logged `.public`, so values are never `<private>`.
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
- First-sync body fetch is capped to the newest 500 messages per mailbox; the
  high-water mark still advances to the newest fetched UID so later syncs stay
  incremental.
- Multi-mailbox sync (INBOX + resolved Sent/Trash); synthetic Sent rows and
  moved-to-Trash rows reconcile to real server UIDs by Message-ID.
- `MailSyncScheduler` (foreground loop + macOS background activity) +
  `MailSyncWorker` + `MailSyncMonitor` status surface.

**Review pipeline**
- `EmailReviewService` (own interval, batch-capped at 40 threads/pass, stamps
  `lastReviewedAt` only after a successful inference pass) + `EmailReviewNotifyTool`.
- Review selection includes opened/read mail as long as it is not archived or
  deleted. Mixed threads only send active messages to the model.
- The review system prompt prepends the configured assistant persona
  (`AssistantPersona.personaPrompt()`) so the user-facing summary message and
  per-item reasons sound in the user's chosen voice. It runs in `.standalone`
  inference mode (the persona is baked into the prompt string rather than
  prepended by `InferenceService`).
- Triage **leans toward recall** (resurfacing): surface anything that plausibly
  needs attention, treat flagged/notated threads as strong "still matters"
  signals (weight user notes heavily), and use `review` as the default when no
  sharper action (reply/flag/delete) fits — drop a thread only when it clearly
  needs nothing. `delete` is reserved for clear junk; "finished but keep" is the
  user's archive call, which the model is not offered. Each pass logs
  `review: sending N thread(s) … (force:)` so a thin pass is diagnosable
  (few-sent = `lastReviewedAt` suppression vs. many-sent-few-surfaced = prompt).
- Deferred hook: once memory ships, feed email memory (e.g. "sender X is spam")
  into the review system prompt so standing notes influence triage.
- Review prompts include date context; review-card rows show subject, sender,
  date, summary, and action. The summary chat message does not append a
  separate date list.
- `ReviewCardPayload` rendering via `ReviewCardRendererRegistry` +
  `EmailReviewCardRenderer`; `EmailReviewActionDispatcher` routes actions
  through the repo + per-account `MailClient`. Acted-upon items drop off the
  card; Reply marks read + flagged so it surfaces in the Flagged mailbox.

**UI**
- `EmailView`: mailbox sidebar (Inbox/Flagged/Archive/Trash, dead mailboxes
  hidden when empty) + thread list + detail. Mark-read on view, two-click
  archive/delete, Delete-Permanently in Trash, reply composer with quoting,
  note editor, attachment list with QuickLook, WKWebView HTML rendering
  preferred when an HTML body is present, with plain text as fallback.
- Email thread/detail rows use plain text, not Markdown, for email bodies.
  Unread rows get a soft tint, noted rows show a notepad popover, and both the
  thread list and thread messages use soft dividers between items.
- HTML email bodies expand to their content height; the embedded WKWebView and
  document scrollbars stay disabled, and scroll gestures over the body pass up
  to the outer thread view.
- Sync Now / Review Now toolbar buttons (with spinner + disabled state),
  dock badge, in-app Chats navigation dot for new review chats, optional
  auto-navigate to the review chat.
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

2. **Conversational follow-up on review chats (next code step).** Let the user
   reply to a review summary and have the assistant act on the referenced
   emails — e.g. "for the email from Suzy, note that it needs a reply by the
   19th and I need to ask her what color cake." Not supported today: the
   review-card message carries `content: ""` (data is in `reviewCardData`), so
   `ChatMessage.inferenceMessage` yields an empty assistant turn — the model
   never sees the card's emails — and `ToolRegistry.shared` has no email tools.
   Design (reuses existing patterns, no `ToolRegistry.shared` container needed):
   - **Context injection** in `ChatCompletionService.completeScopedChat` (which
     already holds the `modelContext` + `Chat`): when the chat contains a
     review card, fetch the referenced emails via `EmailRepository` and append a
     fresh, non-persisted `.system` message listing each — GUID, subject,
     sender, date, a body excerpt, and existing notes — mirroring the transient
     Investigation steering hint. Cap the body excerpt for token cost.
   - **Per-completion email tools** injected for review chats (mirroring how
     `EmailReviewService` injects `EmailReviewNotifyTool` via a one-off
     registry), constructed with the `modelContext`. Start with
     `add_email_note(email_guid, note)`; extensible to flag/reply/delete by
     reusing `EmailReviewActionDispatcher`.
   - Open scope decisions: which actions beyond `add_email_note` to expose, and
     how much body to include. Pairs with the deferred email-memory hook (feed
     standing notes into context so the assistant knows sender-level prefs).

3. **Explicitly deferred (out-of-scope, not active work):**
   - **Phase 0.5 / iOS target** — `.iOS(...)` in `Package.swift`, `#if os(iOS)`
     audit, `BGTaskSchedulerPermittedIdentifiers` in Info.plist, and a
     `BGTaskMailSyncScheduler`. Until then iOS falls back to the foreground loop.
   - **`@Query` windowing in `EmailView`** — not actionable via the `@Query`
     macro; would need `FetchDescriptor` paging. Fine for typical mailboxes.
   - **Per-op connection reuse** — each archive/delete/flag/send op does a fresh
     connect→login→op→disconnect. SwiftMail's per-op lifetime is fine for the
     MVP poll cadence; revisit if a provider rate-limits.
   - **Archive mailbox sync** — archive actions move server mail to the
     provider's Archive/All Mail folder and hide the row locally. Pulling the
     Archive mailbox as a first-class synced mailbox is deferred.

4. **Known by-design behaviors (not bugs):**
   - Optimistic local flag/read mutations can be briefly reverted by
     `reconcileFlagsFromSnapshot` if a sync races the action's server
     round-trip. Self-heals on the next sync; the window is a fraction of the
     300 s poll. Gating it would add bookkeeping for a non-bug.
   - `ThreadResolver` subject clustering is case-sensitive. Revisit only if
     users report mis-threading.
