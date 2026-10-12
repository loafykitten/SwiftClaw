# Email

The Email subsystem lives under `SwiftClaw/Services/Email/`. One
`SwiftMailClient` is created per `StoredEmailAccount`.

Current verification gaps and possible follow-ups are listed at the end.

## Mail client

`SwiftMailClient` reads host/port/username from the account and passwords from
the Keychain per call. For the add-account sheet's Test button (before passwords
are persisted), pass `imapPasswordOverride` / `smtpPasswordOverride` so
`isConfigured` doesn't short-circuit on an empty Keychain.

### IMAP connection reuse

IMAP operations run over persistent per-account connections managed by
`IMAPSession` / `IMAPSessionPool` (`Services/Email/MailClient/IMAPSession.swift`)
instead of a connect → TLS → login → disconnect cycle per call. Two channels
per account: `.sync` for long-running reads (mailbox fetches, UID-set scans,
LIST) and `.interactive` for quick mutations (flags, move, expunge, Sent
APPEND), so a flag toggle never queues behind a 500-message first sync.
Sessions connect + log in lazily, serialize operations FIFO (IMAP SELECT is
connection-global state), probe with NOOP when reused after sitting idle past
a threshold, tear down on any operation error with **no body retry** (MOVE /
APPEND / EXPUNGE aren't idempotent), and close themselves after 60s idle.
The pool key includes host/port/username, so editing account settings rotates
to a fresh session. `testConnection()` deliberately stays on a cold standalone
connection (it must prove a fresh login works, possibly with password
overrides). SMTP stays per-send: sends are infrequent and SMTP servers
aggressively close idle connections. Never call one session-backed
`SwiftMailClient` method from inside another's session closure — the
serialization is non-reentrant and would deadlock.

## Folders

Archive/delete/send resolve the account's real Archive/Trash/Sent folders via
IMAP `LIST (SPECIAL-USE)` (Gmail's archive is `[Gmail]/All Mail`, not
"Archive"), cached on `StoredEmailAccount`. `delete` is a recoverable move to
Trash; `deletePermanently` is the explicit expunge. Expunges are always
UID-scoped (UIDPLUS): without it a move only copies + flags the original
`\Deleted` (`MailClientError.movedWithoutExpunge`) and Delete Permanently
leaves the message flagged (`.targetedExpungeUnsupported`), because a bare
EXPUNGE would also purge mail other clients marked deleted. Delete Permanently
is refused while the row has no server UID (just moved to Trash, awaiting the
Trash sync).

SwiftClaw also caches the account's selectable IMAP folder catalog. Sync covers
INBOX, Sent, Drafts, Junk/Spam, Archive/Trash, and custom folders. Gmail system
folders under `[Gmail]` / `[Google Mail]` that are not real SPECIAL-USE folders
are skipped so unbounded All Mail does not get synced as a custom folder.
Hierarchical folders render flat using their full path, such as
`Work/Receipts`. The sidebar's custom Folders group only shows for a single
account's view — in the unified "All Accounts" view with more than one account
configured, only the standard mailboxes (Inbox/Flagged/Sent/Drafts/Junk/
Archive/Trash) appear, so two accounts' folder lists don't interleave.

## Incremental sync

`fetchMailbox(name:sinceUID:)` returns `MailboxFetchResult { messages,
uidValidity, maxUID }`. `MailSyncWorker` keeps a per-`(account, mailbox)`
high-water mark in `MailboxSyncStateStore`; it fetches `UID > lastSeenUID` when
the recorded UIDVALIDITY still matches, and re-fetches the whole mailbox when it
changed (folder rebuild). Per `syncOnce()` the worker lists or reads the cached
folder catalog, then syncs each selectable folder sequentially for an account.
Each mailbox keeps its own first-sync cap and high-water state. Inject
`clientFactory` / `syncStateProvider` / `syncStateUpdater` to test with
`MockMailClient`.

## Server-side reconciliation

After each incremental upsert the worker runs a cheap `.uidFlagsOnly` UID-set
scan (`MailClient.fetchMailboxUIDSet(name:)` → `MailboxUIDSet { uidValidity,
uids, flagsByUID }`) — no body fetch, one round-trip — and reconciles the local
store: `EmailRepository.reconcileDeletions(...)` soft-deletes (`isTrashed =
true`) local rows whose UID is no longer on the server (preserves the row +
`EmailNote`s + `EmailThread` linkage + `lastReviewedAt`; skipped for
already-archived rows; surfaces in Trash), and
`EmailRepository.reconcileFlagsFromSnapshot(...)` refreshes `\Seen`/`\Flagged`
drift on persisting rows. Drafts reconcile on every pass and hard-delete stale
local draft rows, because editing drafts commonly deletes + re-appends them
with new UIDs. Other synced folders use the normal soft-delete path.
`Email.isTrashed` is the soft-delete flag; never use `isDeleted` on an `Email`,
which is SwiftData's `PersistentModel.isDeleted` (removed from its context).
The attribute keeps its pre-rename `isDeleted` store column via
`@Attribute(originalName:)`.

## Threading

`EmailRepository.resolveThreads()` is incremental and identity-preserving — it
reuses an `EmailThread.id` when a cluster's messages already belonged to it, so
a re-cluster doesn't yank the user's open thread. Only runs when new messages
were inserted.

Threads are account-scoped: it fetches **all** messages (archived and deleted
included), groups them by `Email.accountID`, and clusters each account
separately, stamping `EmailThread.accountID`. A prior thread is only reused
for a same-account (or legacy nil-account) cluster, and clusters with the
strongest prior claim pick first — so legacy mixed-account threads split, with
one account keeping the old thread id and the rest getting fresh rows.

## Review loop

`EmailReviewService.runOnce()` gives the model a scoped `fetch_inbox_emails`
tool, then the model decides which slice of inbox to pull before optionally
calling `notify_user_about_emails`. The service stamps
`EmailThread.lastReviewedAt` only for threads the model actually fetched, and
only after a successful inference call — a failure retries next pass instead of
suppressing threads forever. A thread that, under the fetch's own filter, now
holds a message the payload didn't carry (mail landing mid-inference, or one
restored from Trash) is left unstamped so the unseen message isn't
suppressed. Suppression is via `lastReviewedAt` plus
`reviewedCount`; flagged/notated threads bypass it. The fetched payload
serializes exactly the messages the selection considered
(`EmailRepository.consideredMessages`), so it honors the same folder scope.

Email content is untrusted. The review prompt and fetch result tell the model
not to follow instructions inside thread data. Review follow-up chats keep
trusted guidance first and put referenced emails in a JSON-encoded
`<untrusted_email_data>` block (`<`/`>` escaped so senders can't close the
fence). `add_email_note` / `set_email_flag` only act on emails the chat's own
review cards reference (`EmailReviewToolScope`).

## HTML rendering

`EmailHTMLBodyView` loads sender HTML with content JavaScript disabled, a strict
CSP `<meta>` first in `<head>` (no scripts/frames/forms/`<base>`; only
`data:`/`cid:` images until the user taps "Load Remote Content"), a
non-persistent data store, and a navigation policy that allows only the
`about:` document — clicked http(s)/mailto links open externally, everything
else is cancelled (`EmailHTMLDocument`).

Scheduled review always includes INBOX. Custom folders are excluded by default
and can be opted in per account from Email settings. Junk/Spam, Sent, Drafts,
Trash, and Archive are not scheduled-review folders, but the model can inspect
them on request by calling `fetch_inbox_emails` with an explicit `folders`
filter. The review prompt includes a short folder digest with unread counts
instead of inlining bodies from every folder.

## Replies

Replies populate `In-Reply-To` / `References` from the replied message and
best-effort APPEND to Sent; `EmailRepository.upsertSentMessage` also seeds a
local row (synthetic uid, `isLocallySynthetic = true`) so the reply appears
immediately. The Sent-mailbox sync reconciles the synthetic row to the real one:
when the real server message (matching Message-ID) arrives via `upsertMessages`,
the synthetic row's `uid` is rewritten + the marker flag is cleared — no
duplicate insert.

## Windowed message fetch (large stores)

`EmailView` no longer materializes the whole `Email` table: the `@Query` is
windowed to the newest 1000 messages (`EmailView.initialWindowLimit`) and
grows by `windowStep` via the "Show Older Messages" row at the bottom of the
thread lists. The descriptor is built in `WindowedEmailContent.init` from a
limit the outer `EmailView` owns, since a `@Query`'s descriptor is fixed at
init. Thread detail is unaffected (it reads the full
`EmailThread.messages` relationship); only the thread lists, sidebar
visibility, and search are window-scoped — searching mail older than the
window requires loading older messages first. A pending email selection
(notification / review card) that targets mail outside the window expands it
automatically via a COUNT of newer messages.

## Known limitation

Folder rename on the server is treated as a new folder in the catalog. Rows
under the old name are left alone until a later mailbox operation proves they no
longer exist. That avoids data loss from transient LIST hiccups.

Messages moved between folders in another client can briefly appear in their old
local state until the destination folder sync lands. Archive has a Message-ID
reclaim path; other cross-folder moves may show a temporary duplicate/Trash row
until the next pass settles the store.

## Verification gaps and follow-ups

Live checks still open:

- Reply sends: threads on the recipient side, the APPEND to Sent, and the
  local synthetic row reconciling to the real Sent UID.
- Folder sync live pass: sidebar shows Sent/Drafts/Junk + the account's custom
  folders with plausible contents; Settings → Email → Review Folders lists the
  real folders; toggling one on feeds "Review Now"; with everything off,
  scheduled review matches the previous INBOX-only behavior.
- Large review backlogs: unread/flagged/notated threads
  override the review fetch limit, so a first review over a large unread
  backlog returns every unread thread in one prompt. Intentional and
  self-correcting as the inbox is cleared. If a live first pass produces an
  unwieldy prompt, the fix is a soft cap on the unread override (newest N
  unread), not removing the override.
- IMAP connection reuse landed code-complete with unit coverage
  (`IMAPSessionTests`), but hasn't had a live pass yet: watch a sync pass +
  a flag toggle mid-sync against a real account, and confirm the idle-close
  doesn't fight providers that drop connections early.

Possible follow-ups:

- iOS background mail sync with `BGTaskScheduler`.
- More review follow-up tools (reply/delete) if the review-chat workflow needs
  them.
