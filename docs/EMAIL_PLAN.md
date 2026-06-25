# SwiftClaw Email Feature - Plan & Status

The email feature is code-complete for the current macOS MVP. The only active
remaining work is live end-to-end verification against a real mail account.

Current local verification, June 25, 2026:
- `swift test` passes: 119 tests.
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
- `EmailReviewService` with a separate review interval and a per-pass email
  cap (default 40, configurable in Email settings via "Emails per Review").
- Review selection (`fetchNonArchivedThreadsForReview`): a thread is eligible
  when never reviewed, has new mail since its last review, or was last reviewed
  more than `reviewResurfaceInterval` (7 days) ago — so old read mail keeps
  resurfacing for clearing instead of being suppressed forever. Flagged or
  notated threads always bypass suppression (the user's "this still matters"
  markers). The cap is applied after filtering so older eligible mail isn't
  hidden behind recently-reviewed newest mail.
- Review suppression via `EmailThread.lastReviewedAt`, stamped only after a
  successful inference pass.
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
- `EmailSettingsView` supports account list, add/edit, and Test Connection.

## Remaining Work

The conversational review follow-up is built and hardened (single-message
refresh, honest empty-result handling, lifelong review-chat identity, stale
resurfacing, flagged/notated always-included, configurable per-pass cap) and
passes locally. The next concrete step is the live pass below, then
memory-backed review context once the note/flag loop has real-world use.

**Live end-to-end verification - on Ember's side**
- Test Connection succeeds; account persists; passwords land in Keychain.
- First sync pulls INBOX; threads cluster sensibly.
- Incremental sync fetches only new mail.
- UIDVALIDITY change triggers a full re-fetch.
- Special-use folders resolve per provider.
- Archive, delete-to-Trash, flag, and mark-read reflect on the server.
- Trash sync promotes moved rows to the server Trash UID.
- Delete Permanently expunges the Trash copy and removes the local row.
- Reply sends, threads on the recipient side, APPENDs to Sent, and the local
  synthetic row reconciles to the real Sent UID.
- A review pass creates a review chat; card actions dispatch correctly.
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
