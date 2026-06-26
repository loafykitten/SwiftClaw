# SwiftClaw Email Feature - Plan & Status

The email feature is code-complete for the current macOS MVP. The only active
remaining work is live end-to-end verification against a real mail account.

Current local verification, June 25, 2026:
- `swift test` passes: 149 tests across 22 suites.
  (The `SwiftClawTests` unit-test target and a shared test
  scheme are wired into the project; the test folder is attached as a
  synchronized group, so new test files are picked up automatically.)
- `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build` passes.

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
email date labels are code-complete and pass locally. The next concrete step is
still the live pass below, including the real-store migration check for
`EmailThread.reviewedCount`, then memory-backed review context once the
note/flag loop has real-world use.

One behavior to watch during the live pass (not a code change yet — confirm it
against a real inbox before deciding): unread/flagged/notated threads override
the fetch limit entirely, so a first review over an account with a large unread
backlog returns every unread thread in one prompt. This is intentional
("never miss one that mattered") and self-corrects as the inbox is cleared, but
if the very first live pass produces an unwieldy prompt, the fix is a soft cap
on the unread override (e.g. newest N unread) rather than the current unbounded
return.

**Live end-to-end verification - on Ember's side**
- Test Connection succeeds; account persists; passwords land in Keychain.
- Existing local email store opens successfully after the additive
  `EmailThread.reviewedCount` migration.
- First sync pulls INBOX; threads cluster sensibly.
- Incremental sync fetches only new mail.
- UIDVALIDITY change triggers a full re-fetch.
- Special-use folders resolve per provider.
- Archive, delete-to-Trash, flag, and mark-read reflect on the server.
- Trash sync promotes moved rows to the server Trash UID.
- Delete Permanently expunges the Trash copy and removes the local row.
- Reply sends, threads on the recipient side, APPENDs to Sent, and the local
  synthetic row reconciles to the real Sent UID.
- A review pass calls `fetch_inbox_emails` then `notify_user_about_emails`
  (check `mail.review` / `mail.review.fetch` logs) and creates a review chat;
  card actions dispatch correctly.
- A scheduled/default review over an inbox whose remaining mail is older than a
  week still fetches stale read mail for clearing instead of returning nothing.
- Interval scheduling runs an overdue review after app relaunch; daily local
  review times fire once per configured time and do not repeat after completion.
- Editing a review interval/daily time or switching schedule modes while the app
  is open takes effect immediately.
- Conversational steering reshapes the fetch — e.g. "this week" sets an age
  window, "what's flagged" narrows to flagged — and a second scheduled pass with
  no new mail doesn't re-surface a just-reviewed thread until its decayed window
  elapses (while flagged/notated threads still return).
- Replying in a review chat can add notes and set/clear flags on referenced
  emails.

## Deferred

- iOS target and `BGTaskScheduler` mail sync.
- Archive mailbox sync as a first-class mailbox.
- `EmailView` fetch paging/windowing for very large stores.
- Per-operation IMAP/SMTP connection reuse.
- Memory-backed email review context, such as sender-level preferences.
- More review follow-up tools, such as reply/delete, after the note/flag loop
  is used live.

## Known By-Design Behaviors

- Optimistic local flag/read mutations can briefly be overwritten if a sync
  races the server round-trip. The next sync self-heals.
- `ThreadResolver` subject clustering is case-sensitive unless reply markers
  connect the messages.
