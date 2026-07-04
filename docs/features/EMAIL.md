# Email Feature Notes

The Email subsystem lives under `SwiftClaw/Services/Email/`. One
`SwiftMailClient` is created per `StoredEmailAccount`.

For shipped scope, remaining work, deferred items, and known by-design
behaviors, see [`docs/EMAIL_PLAN.md`](../EMAIL_PLAN.md).

## Mail client

`SwiftMailClient` reads host/port/username from the account and passwords from
the Keychain per call. For the add-account sheet's Test button (before passwords
are persisted), pass `imapPasswordOverride` / `smtpPasswordOverride` so
`isConfigured` doesn't short-circuit on an empty Keychain.

## Folders

Archive/delete/send resolve the account's real Archive/Trash/Sent folders via
IMAP `LIST (SPECIAL-USE)` (Gmail's archive is `[Gmail]/All Mail`, not
"Archive"), cached on `StoredEmailAccount`. `delete` is a recoverable move to
Trash; `deletePermanently` is the explicit expunge.

SwiftClaw also caches the account's selectable IMAP folder catalog. Sync covers
INBOX, Sent, Drafts, Junk/Spam, Archive/Trash, and custom folders. Gmail system
folders under `[Gmail]` / `[Google Mail]` that are not real SPECIAL-USE folders
are skipped so unbounded All Mail does not get synced as a custom folder.
Hierarchical folders render flat using their full path, such as
`Work/Receipts`.

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
store: `EmailRepository.reconcileDeletions(...)` soft-deletes (`isDeleted =
true`) local rows whose UID is no longer on the server (preserves the row +
`EmailNote`s + `EmailThread` linkage + `lastReviewedAt`; skipped for
already-archived rows; surfaces in Trash), and
`EmailRepository.reconcileFlagsFromSnapshot(...)` refreshes `\Seen`/`\Flagged`
drift on persisting rows. Drafts reconcile on every pass and hard-delete stale
local draft rows, because editing drafts commonly deletes + re-appends them
with new UIDs. Other synced folders use the normal soft-delete path.

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
suppressing threads forever. Suppression is via `lastReviewedAt` plus
`reviewedCount`; flagged/notated threads bypass it.

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

## Known limitation

Folder rename on the server is treated as a new folder in the catalog. Rows
under the old name are left alone until a later mailbox operation proves they no
longer exist. That avoids data loss from transient LIST hiccups.

Messages moved between folders in another client can briefly appear in their old
local state until the destination folder sync lands. Archive has a Message-ID
reclaim path; other cross-folder moves may show a temporary duplicate/Trash row
until the next pass settles the store.
