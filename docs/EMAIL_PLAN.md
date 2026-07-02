# SwiftClaw Email Feature - Plan & Status

The email feature is code-complete for the current macOS MVP. Live verification
against a real mail account is mostly complete; the remaining live check is the
reply/Sent reconciliation path.

Current local verification, June 27, 2026:
- `xcodebuild ... test` passes.
  (The `SwiftClawTests` unit-test target and a shared test
  scheme are wired into the project; the test folder is attached as a
  synchronized group, so new test files are picked up automatically.)
- `xcodebuild ... build` passes.

## Shipped Scope

**Data and sync**
- SwiftData models: `Email`, `EmailThread`, `EmailNote`, `EmailAttachment`,
  plus `ChatMessage.reviewCardData`.
- Multi-account storage via `EmailAccountStore`; per-account passwords in
  Keychain.
- `MailClient` protocol with `SwiftMailClient` and `MockMailClient`.
- `EmailRepository` as the mutation boundary for email writes.
- Incremental IMAP sync using UID high-water marks and UIDVALIDITY reset
  handling.
- First sync body fetch capped to the newest 500 messages per mailbox.
- Syncs INBOX plus resolved Sent/Trash folders.
- Server-side deletion and flag reconciliation via cheap UID/flag snapshots.
- Sent reply echo rows reconcile to the real Sent UID by Message-ID.

**Review and chat**
- `EmailReviewService` runs on a separate review interval. The model drives
  inbox selection: each pass exposes a system-only `fetch_inbox_emails` tool the
  model calls first to pull the slice of inbox it wants, then reviews the result
  and calls `notify_user_about_emails`. The scheduled, manual ("Review Now"),
  and conversational-refresh paths all use this two-step flow.
- `fetch_inbox_emails` (backed by `EmailRepository.fetchThreadsForReview`) takes
  optional filters: `max_age_days` (omitted by default, so old read backlog can
  resurface), `limit` (default 10), and include flags for
  flagged/notated/read/unread/archived/trashed. Those omitted-argument defaults
  are configurable in Email settings, while chat steering can still override
  them for one pass (e.g. "this week" sets `max_age_days`, "only five" sets
  `limit`, "what's flagged" narrows to flagged only). Unread, flagged, and
  notated threads override the limit — they're never dropped by the cap;
  flagged/notated also bypass any explicit age window.
- Review suppression via `EmailThread.lastReviewedAt` + `reviewedCount`: a thread
  is eligible when never reviewed, has new mail since its last review, or was last
  reviewed longer ago than its decayed resurface window. The window is
  `min(1 + reviewedCount, 7)` days — a thread loses urgency the more often it's
  shown without action but never escapes (it returns at least weekly), and fresh
  mail resets the counter. Flagged or notated threads always bypass suppression
  (the user's "this still matters" markers). Scheduled passes apply suppression;
  forced/conversational passes turn it off so the model can query the whole
  inbox. Stamping advances `reviewedCount` and happens only after a successful
  pass, on exactly the threads the model fetched.
- The scheduled loop skips the inference call entirely when nothing is eligible
  (`hasThreadsEligibleForReview`), preserving the "don't call the model when
  there's nothing to do" optimization the old inlined pre-fetch gave for free.
- Review scheduling supports either an interval cadence (5 minutes to 24 hours)
  or daily local review times. Successful review completion time is persisted so
  reopening the app can run an overdue interval/daily review immediately.
  Schedule changes in settings restart the sleeping review loop right away, and
  daily first runs wait briefly when overdue so the first sync can land.
- Review prompt leans toward resurfacing and treats age as a valid reason to
  surface, and `delete` may be suggested for any low-value mail (spam, promos,
  notifications, old read mail) — every delete is a user-confirmed suggestion.
- Review prompts and review-chat follow-up context include the user's current
  local date/time and time zone.
- `EmailReviewNotifyTool` creates review chats with email review cards.
- Review card actions route through `EmailReviewActionDispatcher`.
- Review-card follow-up chats now inject referenced email context into the
  next completion.
- Review follow-up tools are scoped per completion, not registered globally:
  `add_email_note(email_guid, note)`, `set_email_flag(email_guid, flagged)`,
  and `refresh_email_review()` (the conversational equivalent of the card's
  updated-analysis button).
- An updated-analysis pass supersedes the prior review card in the chat,
  collapsing it into an "An updated analysis has been requested." label and
  appending the fresh card. Runs on the main context so the UI updates in place.
- When appending to an existing review chat, the pass replays that chat's
  history and switches the prompt to a continuation, so the summary picks up the
  conversation instead of greeting cold.
- Conversational refresh posts a single closing message: the pass suppresses its
  inline summary and the chat assistant relays it as one reply (no duplicate
  "card posted above" follow-up). When a pass surfaces nothing, the tool result
  tells the assistant to say so honestly and ask for direction — never to claim
  a card or new emails appeared when they didn't.
- A chat is treated as a review chat for its whole life (keyed off its title),
  so the email tools and context stay attached even after the card is cleared;
  the assistant never falsely claims it lacks email access.
- In continuation mode the prompt also tells the model the user's latest message
  may steer the run (e.g. "treat anything from Suzy as deletable") and to honor
  it for that pass only — overriding the default `delete` caution when asked.

**UI**
- `EmailView` includes Inbox, Flagged, Archive, and Trash.
- Thread list, detail view, read-on-view, flag/archive/delete, permanent
  delete from Trash, notes, attachments, HTML body rendering, and reply
  composer are implemented.
- `EmailView` mailbox filters are driven by `Email` rows so local delete/archive
  mutations move threads between Inbox/Archive/Trash immediately.
- Toolbar has Sync Now and Review Now with status handling.
- Review cards can navigate to the referenced email; acted-on items drop from
  the card.
- Picking `Review` — via the action badge, swipe, or right-click context menu —
  applies the action and opens the referenced email.
- Review-card summaries expand vertically instead of truncating.
- Review-card rows support left swipe/click-drag for the recommended action,
  with action-colored reveal and no confirmation on release.
- Review cards include an updated-analysis button that appends a fresh manual
  email review to the same Chat instead of creating a separate review chat.
- `EmailSettingsView` supports account list, add/edit, Test Connection, review
  scheduling, and review-fetch defaults.

## Remaining Work

The model-driven `fetch_inbox_emails` selection, the `reviewedCount` resurface
decay, configurable review-fetch defaults, 10-thread default limit, interval and
daily review scheduling, persisted review-completion time, schedule-change
wakeups, first-run delays, same-day relative email date labels, and "Yesterday"
email date labels are code-complete and pass locally. Ember confirmed the real
account path, old-store migration, provider actions, and review-chat note/flag
loop work in live use. The only live provider check still open is reply/Sent.

One behavior to watch during the live pass (not a code change yet — confirm it
against a real inbox before deciding): unread/flagged/notated threads override
the fetch limit entirely, so a first review over an account with a large unread
backlog returns every unread thread in one prompt. This is intentional
("never miss one that mattered") and self-corrects as the inbox is cleared, but
if the very first live pass produces an unwieldy prompt, the fix is a soft cap
on the unread override (e.g. newest N unread) rather than the current unbounded
return.

**Live end-to-end verification**
- Done: real account setup, account persistence, Keychain password storage,
  old-store migration, first sync, incremental sync, special-use folders,
  archive/delete-to-Trash/flag/mark-read server reflection, Trash behavior,
  permanent delete, review pass creation, card actions, scheduling behavior,
  conversational steering, suppression/resurface behavior, and review-chat
  note/flag tools.
- Still open: Reply sends, threads on the recipient side, APPENDs to Sent, and
  the local synthetic row reconciles to the real Sent UID.

## Deferred

- iOS target and `BGTaskScheduler` mail sync.
- Archive mailbox sync as a first-class mailbox.
- `EmailView` fetch paging/windowing for very large stores.
- Per-operation IMAP/SMTP connection reuse.
- Memory-backed email review context, such as sender-level preferences, once
  there are concrete preferences worth remembering.
- More review follow-up tools, such as reply/delete, if the review-chat workflow
  needs them.

### Low-priority cleanup (post-merge)

- `MailSyncWorker.reconcile` uses `preserveSynthetic = (mailbox != "INBOX")`
  as a heuristic for the Sent-folder synthetic-row preservation flag. Compare
  against `account.resolvedSentMailbox` instead — functionally correct today
  (synthetics only land in Sent) but fragile if other mailboxes ever carry
  synthetics.
- `SwiftMailClient`'s three `resolved*Mailbox` accessors each redundantly
  call `resolveSpecialUseMailboxes()`; consolidate into one shared
  `resolveSpecialUseFoldersIfNeeded()` helper.
- `EmailAccountStore.update(_:)` silently re-adds a deleted account if it
  races a mid-sync special-use-folder resolution. Guard against missing index
  (or narrow to `updateCachedMailboxes(for:)` that no-ops on missing account).
- `EmailReviewDescriptors` allocates a fresh `DateFormatter` per call (per
  message in a tight loop). Cache as `static let` or use `Date.FormatStyle`.
- `ThreadResolver` doc comment overstates the case-sensitivity gap — the
  prefix comparison lower-cases, only the subject body is case-sensitive.
- `Email.stripHTML` comment claims "excessive" blank lines collapsed; the
  implementation collapses all blank lines. Fix the comment or the behavior.
- `EmailReviewService.systemPrompt` embeds persona with `.standalone` mode
  (inverse of the AGENTS.md `.prependPersona` convention). Intentional to
  avoid double-stamping — add a comment noting the exemption so a future
  reader doesn't "fix" it by switching to `.prependPersona`.
- `MockMailClient` uses `@preconcurrency MailClient` — likely unnecessary
  now that `MailClient` is cleanly `Sendable`.
- `EmailView.swift:1066` (now in `EmailReplyComposerView.swift`) has a
  redundant `at < address.endIndex` bound check (always true when
  `lastIndex(of: "@")` returns non-nil). Drop it.
- `EmailHTMLView` uses string-KVC `setValue(false, forKey: "drawsBackground")`
  on WKWebView. Migrate to `isOpaque = false` + `underPageBackgroundColor =
  .clear` when convenient.
- Tests: consolidate the three private `UserDefaultsFixture` copies — already
  done; one shared fixture lives in `SwiftClawTests/Fixtures/`. Remaining test
  cleanup: tighten brittle substring/`"threadID"`-count assertions in
  `EmailReviewFetchTests`; the under-discriminating stale-resurface test in
  `EmailRepositoryTests`; the `||` singular/plural assertion in
  `EmailReviewNotifyToolTests`.
- `EmailServerAction.delete` reads `EmailAccountStore.shared` directly (no
  injection seam), so the "repoint local row to the resolved Trash mailbox
  when it differs from the optimistic fallback" branch is uncovered by tests.
  Add an `accountStore:` parameter to `EmailServerAction`'s methods (or
  thread one through `EmailReviewActionDispatcher`) so the repoint path can
  be exercised without mutating process-wide state under parallel execution.

## Known By-Design Behaviors

- Optimistic local flag/read mutations can briefly be overwritten if a sync
  races the server round-trip. The next sync self-heals.
- `ThreadResolver` subject clustering is case-sensitive unless reply markers
  connect the messages.
