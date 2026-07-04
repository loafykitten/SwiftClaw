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

## Incremental sync

`fetchMailbox(name:sinceUID:)` returns `MailboxFetchResult { messages,
uidValidity, maxUID }`. `MailSyncWorker` keeps a per-`(account, mailbox)`
high-water mark in `MailboxSyncStateStore`; it fetches `UID > lastSeenUID` when
the recorded UIDVALIDITY still matches, and re-fetches the whole mailbox when it
changed (folder rebuild). Per `syncOnce()` the worker iterates `[INBOX,
account's resolved Sent folder]` and runs the upsert + reconciliation against
each. Inject `clientFactory` / `syncStateProvider` / `syncStateUpdater` to test
with `MockMailClient`.

## Server-side reconciliation

After each incremental upsert the worker runs a cheap `.uidFlagsOnly` UID-set
scan (`MailClient.fetchMailboxUIDSet(name:)` → `MailboxUIDSet { uidValidity,
uids, flagsByUID }`) — no body fetch, one round-trip — and reconciles the local
store: `EmailRepository.reconcileDeletions(...)` soft-deletes (`isDeleted =
true`) local rows whose UID is no longer on the server (preserves the row +
`EmailNote`s + `EmailThread` linkage + `lastReviewedAt`; skipped for
already-archived rows; surfaces in Trash), and
`EmailRepository.reconcileFlagsFromSnapshot(...)` refreshes `\Seen`/`\Flagged`
drift on persisting rows. MVP scope: INBOX only. Soft-deleted rows naturally
clean up stale old-UID rows after a UIDVALIDITY-rebuild.

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

## Replies

Replies populate `In-Reply-To` / `References` from the replied message and
best-effort APPEND to Sent; `EmailRepository.upsertSentMessage` also seeds a
local row (synthetic uid, `isLocallySynthetic = true`) so the reply appears
immediately. The Sent-mailbox sync reconciles the synthetic row to the real one:
when the real server message (matching Message-ID) arrives via `upsertMessages`,
the synthetic row's `uid` is rewritten + the marker flag is cleared — no
duplicate insert.

## Known limitation

Server→local reconciliation is **INBOX only** for the deletion-reconciliation
pass that soft-deletes, plus per-account Sent for the upsert + flag/deletion
reconciliation. The `MailSyncWorker.syncOnce()` runs the UID-set scan +
deletion/flag reconciliation against every mailbox it syncs (INBOX + the
account's resolved Sent folder). For Sent-mailbox reconciliation, the
locally-synthetic rows `upsertSentMessage` produces are preserved until a real
Sent-folder sync lands the matching Message-ID (recognized by the
`isLocallySynthetic` flag, set on send and cleared on promotion). Extending to
Archive/Trash belongs with further multi-mailbox-sync work — those mailboxes are
reflected as local soft-delete flags today, so server-side membership
reconciliation on them is lower priority.
