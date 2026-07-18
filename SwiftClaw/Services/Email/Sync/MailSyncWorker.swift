import Foundation
import SwiftData
import os

/// Performs the actual mail pull → upsert → thread-resolution work on a
/// background actor, with all SwiftData mutations funneled through the
/// MainActor `EmailRepository`. The scheduler layer owns one of these.
///
/// Multi-account: on each `syncOnce()` the worker snapshots the current
/// `StoredEmailAccount` list via `accountsProvider` and syncs each complete
/// account in turn, tagging upserted messages with the account's UUID.
///
/// Multi-mailbox: per account the worker iterates a list of mailbox names
/// to sync (INBOX + resolved Sent/Trash folders). Per-mailbox state
/// lives in `MailboxSyncStateStore` (keyed by `(accountID, mailbox)`), so
/// the per-mailbox high-water + UIDVALIDITY tracking needs no change.
/// Sent-mailbox sync finally reconciles the locally-synthetic rows
/// `upsertSentMessage` seeded (the upsert path rewrites them with the real
/// server uid + clears `isLocallySynthetic` when the matching Message-ID
/// arrives).
///
/// Incremental fetch: for each `(account, mailbox)` the worker asks
/// `syncStateProvider` for the last recorded high-water mark + UIDVALIDITY.
/// If the stored validity matches the live mailbox, only messages with UID >
/// `lastSeenUID` are fetched; otherwise (first sync, or folder rebuild) the
/// mailbox is fetched in full. After the fetch, `syncStateUpdater` records
/// the new high-water for next time.
actor MailSyncWorker {
    static let firstSyncMaxMessages = 500

    private static let logger = AppLog.make("mail.sync")

    /// Run the expensive full-UID-set deletion reconciliation only every Nth
    /// `syncOnce`. The incremental fetch + flag sync still runs every pass; only
    /// the extra uncapped `fetchMailboxUIDSet` round-trip per mailbox (which
    /// exists to catch deletions made from *other* clients) is throttled.
    /// App-initiated deletes are already reflected optimistically, so up to N
    /// intervals of latency on an externally-deleted message is an acceptable
    /// trade for cutting steady-state IMAP traffic by ~Nx on a quiet inbox.
    /// Injectable so reconciliation tests can force it on every pass.
    private let reconcileEveryNPasses: Int

    /// Counts `syncOnce` invocations so deletion reconciliation can run on a
    /// slower cadence than the incremental fetch (see `reconcileEveryNPasses`).
    private var passCount = 0
    private var inFlightSync: Task<Int, Never>?

    private let accountsProvider: @Sendable () async -> [StoredEmailAccount]
    private let modelContainer: ModelContainer
    private let clientFactory: @Sendable (StoredEmailAccount) -> MailClient
    private let syncStateProvider: @Sendable (UUID, String) async -> MailboxSyncState?
    private let syncStateUpdater: @Sendable (MailboxSyncState, UUID, String) async -> Void
    /// Receives the pass's new unread inbox messages (all accounts) so
    /// `AppNotificationService` can post new-mail notifications. Injectable
    /// like `syncStateProvider` so tests capture instead of posting.
    private let newMailNotifier: @Sendable ([NewMailNotificationInfo]) async -> Void

    init(
        accountsProvider: @escaping @Sendable () async -> [StoredEmailAccount],
        modelContainer: ModelContainer,
        clientFactory: @escaping @Sendable (StoredEmailAccount) -> MailClient = { SwiftMailClient(account: $0) },
        syncStateProvider: @escaping @Sendable (UUID, String) async -> MailboxSyncState? = { accountID, mailbox in
            await MainActor.run { MailboxSyncStateStore.shared.state(for: accountID, mailbox: mailbox) }
        },
        syncStateUpdater: @escaping @Sendable (MailboxSyncState, UUID, String) async -> Void = { state, accountID, mailbox in
            await MainActor.run { MailboxSyncStateStore.shared.update(state, for: accountID, mailbox: mailbox) }
        },
        newMailNotifier: @escaping @Sendable ([NewMailNotificationInfo]) async -> Void = { infos in
            await MainActor.run { AppNotificationService.shared.notifyNewMail(infos) }
        },
        reconcileEveryNPasses: Int = 4
    ) {
        self.accountsProvider = accountsProvider
        self.modelContainer = modelContainer
        self.clientFactory = clientFactory
        self.syncStateProvider = syncStateProvider
        self.syncStateUpdater = syncStateUpdater
        self.newMailNotifier = newMailNotifier
        self.reconcileEveryNPasses = reconcileEveryNPasses
    }

    /// Returns the total number of newly-inserted messages across all
    /// accounts + synced mailboxes.
    @discardableResult
    func syncOnce() async -> Int {
        if let inFlightSync {
            return await inFlightSync.value
        }
        let task = Task { await self.performSyncOnce() }
        inFlightSync = task
        let result = await task.value
        inFlightSync = nil
        return result
    }

    private func performSyncOnce() async -> Int {
        let accounts = (await accountsProvider()).filter { $0.isComplete }
        guard !accounts.isEmpty else {
            Self.logger.info("syncOnce skipped — no configured mail accounts")
            await MainActor.run {
                MailSyncMonitor.shared.setStatus("Email not configured", syncing: false)
            }
            return 0
        }

        await MainActor.run {
            MailSyncMonitor.shared.setStatus("Syncing mail…", syncing: true)
        }

        passCount += 1
        // Run on the first pass and every Nth pass thereafter so a freshly
        // started worker reconciles immediately, then settles into the cheaper
        // cadence. (`passCount` starts at 1, so subtract 1 before the modulo —
        // this also makes N == 1 reconcile every pass.)
        let shouldReconcile = (passCount - 1) % reconcileEveryNPasses == 0

        // Accounts use independent `MailClient`s / IMAP connections, so their
        // network round-trips can overlap — run them concurrently and sum the
        // results. (Mailboxes within an account still sync sequentially; they
        // share one connection.)
        let totals = await withTaskGroup(of: AccountSyncResult.self) { group in
            for account in accounts {
                group.addTask {
                    await self.syncAccount(account, reconcile: shouldReconcile)
                }
            }
            var totalInserted = 0
            var totalRemoved = 0
            var newMail: [NewMailNotificationInfo] = []
            for await result in group {
                totalInserted += result.inserted
                totalRemoved += result.removed
                newMail.append(contentsOf: result.newMail)
            }
            return (inserted: totalInserted, removed: totalRemoved, newMail: newMail)
        }

        await MainActor.run {
            MailSyncMonitor.shared.recordCompleted(
                newMessageCount: totals.inserted,
                removedCount: totals.removed
            )
        }
        if !totals.newMail.isEmpty {
            await newMailNotifier(totals.newMail)
        }
        return totals.inserted
    }

    /// Syncs one account's mailboxes in sequence (they share a single IMAP
    /// connection, so mailbox-level parallelism isn't safe) and returns the
    /// per-account inserted + soft-deleted counts. `syncOnce` runs these
    /// concurrently across accounts.
    private func syncAccount(
        _ account: StoredEmailAccount,
        reconcile shouldReconcile: Bool
    ) async -> AccountSyncResult {
        let client = clientFactory(account)
        // Sync INBOX + the account's resolved Sent/Trash folders. INBOX
        // is always attempted; Sent/Trash are skipped when the account can't
        // resolve one (a brand-new install + the user hasn't taken a
        // delete/archive/send action yet to cache the special-use name).
        let mailboxes = await Self.mailboxesToSync(
            for: account,
            client: client,
            refreshCatalog: shouldReconcile
        )
        var inserted = 0
        var removed = 0
        var newMail: [NewMailNotificationInfo] = []
        for mailbox in mailboxes {
            do {
                let mailboxResult = try await syncMailbox(
                    mailbox,
                    account: account,
                    client: client
                )
                inserted += mailboxResult.insertedCount
                newMail.append(contentsOf: mailboxResult.newMail)
                // Reconcile per mailbox, throttled to every Nth pass.
                if shouldReconcile || mailbox.role == .drafts {
                    removed += await reconcile(
                        client: client,
                        mailbox: mailbox,
                        accountID: account.id
                    )
                }
            } catch {
                // EffectiveDisplayName resolves to the IMAP username /
                // from address (PII), and `error` payloads can include
                // server hostnames/usernames echoed back from the
                // provider. Keep both at default privacy — only mailbox
                // *names* and counts/booleans are non-sensitive enough
                // for `.public`.
                Self.logger.error("""
                    syncOnce failed for \(mailbox.name, privacy: .public) on \
                    \(account.effectiveDisplayName): \
                    \(String(describing: error))
                    """)
            }
        }
        if inserted > 0 {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                EmailRepository(modelContext: context).resolveThreads(for: account.id)
            }
        }
        return AccountSyncResult(inserted: inserted, removed: removed, newMail: newMail)
    }

    /// Returns the account's folder catalog as the sync set, listing (or
    /// re-listing on reconcile passes) from the server when needed.
    /// Best-effort: a failed LIST falls back to the cached catalog, then to
    /// INBOX plus whichever special-use names are already resolved.
    private static func mailboxesToSync(
        for account: StoredEmailAccount,
        client: MailClient,
        refreshCatalog: Bool
    ) async -> [SyncedMailbox] {
        if account.folders == nil || refreshCatalog {
            do {
                return syncedMailboxes(from: try await client.listFolders(), account: account)
            } catch {
                if let cached = account.folders {
                    return syncedMailboxes(from: cached, account: account)
                }
                return fallbackMailboxes(for: account)
            }
        }

        return syncedMailboxes(from: account.folders ?? [], account: account)
    }

    private static func syncedMailboxes(
        from folders: [MailFolderDescriptor],
        account: StoredEmailAccount
    ) -> [SyncedMailbox] {
        var boxes: [SyncedMailbox] = []
        for folder in folders where !folder.name.isEmpty {
            if !boxes.contains(where: { $0.name.caseInsensitiveCompare(folder.name) == .orderedSame }) {
                boxes.append(SyncedMailbox(
                    name: folder.name,
                    role: account.folderRole(forMailbox: folder.name) ?? folder.role
                ))
            }
        }
        // INBOX always syncs, even off a pathological inbox-less catalog
        // (RFC 3501 guarantees it exists server-side).
        if !boxes.contains(where: { $0.role == .inbox }) {
            boxes.insert(SyncedMailbox(name: "INBOX", role: .inbox), at: 0)
        }
        return boxes
    }

    private static func fallbackMailboxes(for account: StoredEmailAccount) -> [SyncedMailbox] {
        var boxes = [SyncedMailbox(name: "INBOX", role: .inbox)]

        func append(_ name: String?, role: MailFolderRole) {
            guard let name, !name.isEmpty else { return }
            if !boxes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                boxes.append(SyncedMailbox(name: name, role: role))
            }
        }

        append(account.sentMailbox, role: .sent)
        append(account.draftsMailbox, role: .drafts)
        append(account.trashMailbox, role: .trash)
        append(account.archiveMailbox, role: .archive)
        append(account.junkMailbox, role: .junk)
        return boxes
    }

    /// Fetches + upserts one mailbox for one account. Returns the count of
    /// newly-inserted messages plus the subset eligible for a new-mail
    /// notification (unread inbox arrivals on an established sync state).
    private func syncMailbox(
        _ syncedMailbox: SyncedMailbox,
        account: StoredEmailAccount,
        client: MailClient
    ) async throws -> MailboxSyncOutcome {
        let mailbox = syncedMailbox.name
        let stored = await syncStateProvider(account.id, mailbox)
        let didHavePriorState = (stored?.uidValidity ?? 0) > 0
        let sinceUID: UInt32? = didHavePriorState ? stored?.lastSeenUID : nil

        let firstSyncLimit = didHavePriorState ? nil : Self.firstSyncMaxMessages
        var result = try await client.fetchMailbox(
            name: mailbox,
            sinceUID: sinceUID,
            maxMessages: firstSyncLimit
        )

        // UIDVALIDITY safety: when a server rebuilds a folder every UID is
        // reassigned, so the old `(accountID, uid, mailbox)` dedup key no
        // longer identifies the same message. The incremental `sinceUID`
        // we passed in is meaningless against the new numbering. If the live
        // UIDVALIDITY doesn't match what we recorded for this folder we
        // *must* re-fetch the whole mailbox — otherwise rebuilt messages
        // whose new UID lands at or below the stale high-water are silently
        // lost, and a brand-new message landing on a recycled low UID
        // reconciles flags onto a stale local row instead of inserting.
        let didReset = didHavePriorState && stored?.uidValidity != result.uidValidity
        if didReset {
            Self.logger.notice("""
                UIDVALIDITY changed for \(mailbox, privacy: .public) \
                (\(stored?.uidValidity ?? 0, privacy: .public) → \
                \(result.uidValidity, privacy: .public)); refetching full mailbox.
                """)
            // Refetch the WHOLE mailbox uncapped. The first-sync cap is
            // deliberately NOT reused here: a reset reassigns every UID, so the
            // local rows now carry dead uids that match no current server uid.
            // The reconcile pass (`fetchMailboxUIDSet` + `reconcileDeletions`)
            // runs against the full *live* UID set, so any message we hold but
            // don't re-fetch this pass looks server-absent and gets wrongly
            // soft-deleted. Pulling everything lets upsert re-key each row by
            // Message-ID (preserving notes/flags) and keeps deletion
            // reconciliation honest. A reset is rare, so the one-time full pull
            // is an acceptable cost for not silently dropping the user's mail.
            result = try await client.fetchMailbox(
                name: mailbox,
                sinceUID: nil,
                maxMessages: nil
            )
        }

        // On a UIDVALIDITY-reset refetch into an empty/rebuilt folder,
        // `result.maxUID` is nil; falling back to the stale `sinceUID` from
        // the dead UIDVALIDITY would record a high-water higher than any real
        // UID in the rebuilt folder, so the next incremental pass would skip
        // everything that arrived. Use 0 instead — the rebuild resets the
        // position, and the next fetch pulls `> 0` correctly.
        let nextLastSeen: UInt32 = result.maxUID ?? (didReset ? 0 : (sinceUID ?? 0))
        let newState = MailboxSyncState(
            uidValidity: result.uidValidity,
            lastSeenUID: nextLastSeen
        )
        await syncStateUpdater(newState, account.id, mailbox)

        // Anti-spam guard: the first sync of an account (no prior state) and
        // a UIDVALIDITY rebuild both re-pull historical mail that is not
        // "new" to the user — neither pass may emit notifications.
        let suppressNotifications = !didHavePriorState || didReset

        let outcome = await upsert(
            fetched: result.messages,
            mailbox: mailbox,
            accountID: account.id,
            role: syncedMailbox.role
        )

        let newMail: [NewMailNotificationInfo]
        if syncedMailbox.role == .inbox && !suppressNotifications {
            newMail = outcome.inserted
                .filter { !$0.isRead }
                .map { summary in
                    NewMailNotificationInfo(
                        emailID: summary.id,
                        accountID: account.id,
                        fromDisplay: summary.fromDisplay,
                        subject: summary.subject,
                        snippet: summary.snippet
                    )
                }
        } else {
            newMail = []
        }
        return MailboxSyncOutcome(insertedCount: outcome.insertedCount, newMail: newMail)
    }

    private func upsert(
        fetched: [FetchedMessage],
        mailbox: String,
        accountID: UUID,
        role: MailFolderRole
    ) async -> EmailUpsertOutcome {
        // File I/O stays off MainActor; the repository receives only metadata
        // and prepared relative paths for its SwiftData transaction.
        let prepared = EmailAttachmentStore.shared.prepare(fetched)
        let outcome = await MainActor.run {
            let context = ModelContext(modelContainer)
            let repository = EmailRepository(modelContext: context)
            return repository.upsertPreparedMessages(
                prepared,
                mailbox: mailbox,
                accountID: accountID,
                role: role
            )
        }
        let insertedIDs = Set(outcome.inserted.map(\.id))
        EmailAttachmentStore.shared.deletePreparedMessages(
            prepared.filter { !insertedIDs.contains($0.emailID) }
        )
        return outcome
    }

    /// Runs the per-`(account, mailbox)` server-side reconciliation pass and
    /// returns the count of local rows newly soft-deleted. Flag refresh is
    /// best-effort — its count isn't surfaced here (the monitor only reports
    // new + removed; flag changes are silent UI events).
    private func reconcile(
        client: MailClient,
        mailbox: SyncedMailbox,
        accountID: UUID
    ) async -> Int {
        // `syncMailbox` already wrote the post-fetch state via
        // `syncStateUpdater` before this runs, so `stored` reflects the
        // mailbox as synced this pass (not pre-sync). On the very first sync
        // of a brand-new mailbox that just-populated state is what lets the
        // reconciliation pass run here too; the guard only short-circuits when
        // the mailbox genuinely has no recorded UIDVALIDITY (e.g. the empty-
        // inbox early-return path above left state untouched). Harmless either
        // way — the cheap UID-set scan against a just-fetched mailbox simply
        // re-confirms the rows that were upserted a moment ago.
        let stored = await syncStateProvider(accountID, mailbox.name)
        guard (stored?.uidValidity ?? 0) > 0 else { return 0 }

        do {
            let snapshot = try await client.fetchMailboxUIDSet(name: mailbox.name)
            return await MainActor.run {
                let context = ModelContext(modelContainer)
                let repository = EmailRepository(modelContext: context)
                let preserveSynthetic = mailbox.role == .sent
                return repository.reconcileMailbox(
                    snapshot,
                    mailbox: mailbox.name,
                    accountID: accountID,
                    preserveLocallySynthetic: preserveSynthetic,
                    hardDelete: mailbox.role == .drafts
                ).removedCount
            }
        } catch {
            // The cheap UID-set scan is a background reconciliation; if it
            // fails the upsert already succeeded for this pass. Surface a
            // non-fatal log and move on — the next sync retries.
            Self.logger.notice("""
                reconcile UID-set scan failed for \(mailbox.name, privacy: .public): \
                \(String(describing: error))
                """)
            return 0
        }
    }
}

private struct SyncedMailbox: Sendable {
    let name: String
    let role: MailFolderRole
}

private struct MailboxSyncOutcome: Sendable {
    let insertedCount: Int
    let newMail: [NewMailNotificationInfo]
}

private struct AccountSyncResult: Sendable {
    let inserted: Int
    let removed: Int
    let newMail: [NewMailNotificationInfo]
}
