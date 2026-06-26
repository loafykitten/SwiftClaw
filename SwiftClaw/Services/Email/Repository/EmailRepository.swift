import Foundation
import SwiftData
import os

/// Single mutation boundary for all Email/SwiftData writes. The first
/// repository abstraction in the codebase — call out new repositories in
/// `AGENTS.md` when introducing them.
///
/// Mutations are MainActor-isolated. Reads intended for the UI go through
/// `@Query` in views; this repository is for sync, flag reconciliation,
/// threading, and review selection.
@MainActor
final class EmailRepository {
    private static let logger = AppLog.make("mail.repository")

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Upsert

    /// Inserts new messages and updates flags/bodies for already-known messages.
    /// Returns the count of newly inserted messages.
    @discardableResult
    func upsertMessages(
        _ fetched: [FetchedMessage],
        mailbox: String,
        accountID: UUID,
        isDeletedMailbox: Bool = false,
        isArchiveMailbox: Bool = false
    ) -> Int {
        guard !fetched.isEmpty else { return 0 }
        var inserted = 0
        let existing = fetchExistingMailboxIndex(uids: fetched.map(\.uid), mailbox: mailbox, accountID: accountID)
        // Fallback dedup for locally-synthetic Sent rows seeded by
        // `upsertSentMessage` before a real Sent-folder sync. Such rows use
        // a client-side uid with no server counterpart, so the UID-based
        // index above won't find them — but their `messageID` matches the
        // real server message. When the real row arrives we rewrite the
        // synthetic row's uid + clear `isLocallySynthetic` instead of
        // inserting a duplicate. See `upsertSentMessage` for the full
        // synthetic-row lifecycle.
        let messageIDsToFetched: [String: FetchedMessage] = {
            var dict: [String: FetchedMessage] = [:]
            for message in fetched {
                guard let mid = message.messageID, !mid.isEmpty else { continue }
                if dict[mid] == nil { dict[mid] = message }
            }
            return dict
        }()
        let existingByMessageID = fetchExistingByMessageID(
            messageIDs: Array(messageIDsToFetched.keys),
            mailbox: mailbox,
            accountID: accountID
        )
        // When syncing a real `\Archive` folder, a message archived from
        // another client has left INBOX (the deletion pass may have already
        // soft-deleted its local row earlier in this very sync). Match it back
        // by `messageID` across mailboxes and reclaim that row as archived,
        // rather than inserting a duplicate Archive copy and leaving a
        // wrongly-trashed INBOX row behind.
        let reclaimable = isArchiveMailbox
            ? fetchArchiveReclaimCandidates(
                messageIDs: Array(messageIDsToFetched.keys),
                archiveMailbox: mailbox,
                accountID: accountID
            )
            : [:]

        for message in fetched {
            if let existingEmail = existing[message.uid] {
                reconcileFlags(existing: existingEmail, fetched: message)
            } else if let mid = message.messageID, !mid.isEmpty,
                      let synthetic = existingByMessageID[mid] {
                // Real Sent-folder sync arrived for a row we synthed locally.
                // Promote it: rewrite the synthetic uid to the real server
                // uid + clear `isLocallySynthetic` (see `upsertSentMessage`).
                synthetic.uid = message.uid
                synthetic.isLocallySynthetic = false
                reconcileFlags(existing: synthetic, fetched: message)
            } else if let mid = message.messageID, !mid.isEmpty,
                      let reclaimed = reclaimable[mid] {
                // Server-side archive of a message we still hold under INBOX
                // (or had just soft-deleted this pass): move the existing row
                // into the Archive mailbox instead of inserting a second copy.
                reclaimed.uid = message.uid
                reclaimed.mailbox = mailbox
                reclaimed.isArchived = true
                reclaimed.isDeleted = false
                reconcileFlags(existing: reclaimed, fetched: message)
            } else {
                insert(
                    message: message,
                    mailbox: mailbox,
                    accountID: accountID,
                    isDeletedMailbox: isDeletedMailbox,
                    isArchiveMailbox: isArchiveMailbox
                )
                inserted += 1
            }
        }

        do {
            try modelContext.save()
        } catch {
            Self.logger.error("upsertMessages save failed: \(String(describing: error))")
        }

        return inserted
    }

    // MARK: - Flags / archive / delete

    func archive(messageID: UUID) {
        guard let email = fetchEmail(by: messageID) else { return }
        email.isArchived = true
        save()
    }

    func delete(messageID: UUID, movedToMailbox mailbox: String? = nil) {
        guard let email = fetchEmail(by: messageID) else { return }
        email.isDeleted = true
        if let mailbox, !mailbox.isEmpty {
            email.mailbox = mailbox
        }
        save()
    }

    /// Irrecoverable delete: actually removes the row + its `EmailNote`s
    /// (via the cascade rule) + the on-disk attachment bytes from
    /// `EmailAttachmentStore`. Only the Trash mailbox "Delete Permanently"
    /// affordance should call this — the regular `delete` is a recoverable
    /// move to Trash. The server-side expunge happens elsewhere via
    /// `MailClient.deletePermanently(uid:in:)`; this is the local-side half.
    func deletePermanently(messageID: UUID) {
        guard let email = fetchEmail(by: messageID) else { return }
        let emailID = email.id
        // Clean the on-disk attachment bytes BEFORE the row goes away (the
        // SwiftData cascade rule only deletes the `EmailAttachment` rows,
        // not the files in `~/Library/Application Support/SwiftClaw/EmailAttachments/`).
        EmailAttachmentStore.shared.deleteAttachments(forEmailID: emailID)
        modelContext.delete(email)
        save()
    }

    /// Sets the read state on a message. Used by `EmailThreadDetailView`
    /// when the user opens a thread (latest message marked read).
    func setRead(messageID: UUID, isRead: Bool) {
        guard let email = fetchEmail(by: messageID) else { return }
        guard email.isRead != isRead else { return }
        email.isRead = isRead
        // Mark unsynced so a stale server snapshot can't revert this before
        // `EmailServerAction` confirms the change server-side.
        email.needsFlagSync = true
        save()
    }

    /// Toggles the flag on a message. Returns the new flag state so the
    /// caller can mirror it to the server without re-reading the model.
    @discardableResult
    func toggleFlag(messageID: UUID) -> Bool? {
        guard let email = fetchEmail(by: messageID) else { return nil }
        email.isFlagged.toggle()
        email.needsFlagSync = true
        save()
        return email.isFlagged
    }

    /// Sets the flag state on a message (unlike `toggleFlag`, sets to an
    /// explicit value rather than flipping). Used by the review dispatcher's
    /// `.reply` path which flags + marks read. Returns the new flag state.
    @discardableResult
    func setFlag(messageID: UUID, isFlagged: Bool) -> Bool? {
        guard let email = fetchEmail(by: messageID) else { return nil }
        guard email.isFlagged != isFlagged else { return email.isFlagged }
        email.isFlagged = isFlagged
        email.needsFlagSync = true
        save()
        return email.isFlagged
    }

    /// Clears the pending-flag-sync marker once `EmailServerAction` has
    /// confirmed the local `isRead`/`isFlagged` change landed on the server.
    /// After this the row is fair game for `reconcileFlagsFromSnapshot` again.
    func clearFlagSyncPending(messageID: UUID) {
        guard let email = fetchEmail(by: messageID) else { return }
        guard email.needsFlagSync else { return }
        email.needsFlagSync = false
        save()
    }

    // MARK: - Notes

    @discardableResult
    func addNote(emailID: UUID, author: EmailNoteAuthor, content: String) -> EmailNote? {
        guard let email = fetchEmail(by: emailID) else { return nil }
        let note = EmailNote(email: email, author: author, content: content)
        email.notes.append(note)
        save()
        return note
    }

    // MARK: - Threading

    /// Re-clusters visible (non-archived/non-deleted) messages into threads
    /// using an identity-stable, incremental algorithm:
    ///
    /// 1. Snapshot, per visible message, which `EmailThread` it currently
    ///    belongs to (so `EmailThread.id` survives a re-cluster).
    /// 2. Run `ThreadResolver.cluster(...)` purely for its message grouping.
    /// 3. For each cluster, reuse the prior thread that the *most* messages
    ///    in that cluster already belonged to (stable identity). A prior
    ///    thread can be claimed by at most one cluster — subsequent clusters
    ///    that also pointed at it get fresh threads. Clusters that map to
    ///    no prior thread get a freshly-allocated `EmailThread`.
    /// 4. Re-attach visible messages to their canonical thread by id.
    /// 5. Delete prior threads that are now truly empty (no visible AND no
    ///    archived/deleted stragglers still attached).
    ///
    /// Archived/deleted messages are never fetched here, so they remain
    /// attached to whatever threads they were on — their threads are
    /// preserved as long as they still own at least one message.
    func resolveThreads() {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { !$0.isArchived && !$0.isDeleted }
        )
        guard let messages = try? modelContext.fetch(descriptor),
              !messages.isEmpty else {
            return
        }

        // Snapshot prior thread identity per visible message (keyed by
        // message.id) BEFORE we mutate anything. We use this map to pick
        // the canonical thread for each fresh cluster.
        let priorThreadByMessageID: [UUID: EmailThread] = Dictionary(
            messages.compactMap { message in
                message.thread.map { (message.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Compute fresh cluster groupings. We use `ThreadResolver.cluster`
        // only for its grouping logic; the freshly-allocated `EmailThread`
        // objects it returns are discarded (we reassign messages to either
        // an existing reused thread or a fresh thread we control).
        let freshClusters = ThreadResolver.cluster(messages)
        let groupings: [(messageIDs: [UUID], subject: String, firstDate: Date, lastDate: Date)] =
            freshClusters.map { cluster in
                (
                    messageIDs: cluster.messages.map(\.id),
                    subject: cluster.subjectNormalized,
                    firstDate: cluster.firstDate,
                    lastDate: cluster.lastDate
                )
            }

        let messagesByID: [UUID: Email] = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Detach ALL visible messages from any thread (including the
        // freshly-allocated ones ThreadResolver attached them to). We're
        // about to reassign them deliberately.
        for message in messages {
            message.thread = nil
        }

        // Index still-persisted threads by id so we can look them up to
        // reuse, and track — via `claimedExistingThreadIDs` — which existing
        // thread has already been claimed by a cluster (prevents a split
        // cluster from re-merging onto a previously-claimed thread).
        var existingThreadByID: [UUID: EmailThread] = [:]
        (try? modelContext.fetch(FetchDescriptor<EmailThread>()))?.forEach { thread in
            existingThreadByID[thread.id] = thread
        }
        var claimedExistingThreadIDs: Set<UUID> = []

        for grouping in groupings {
            // Pick the prior thread that the largest number of this
            // cluster's messages already belonged to. Only existing
            // (un-claimed) threads are eligible — a prior thread gets
            // reused for exactly one cluster so identity stays stable.
            let candidateCount: [UUID: Int] = grouping.messageIDs.reduce(into: [:]) { counts, mid in
                if let thread = priorThreadByMessageID[mid] {
                    counts[thread.id, default: 0] += 1
                }
            }
            let canonicalID = candidateCount
                .filter { !claimedExistingThreadIDs.contains($0.key) }
                .max(by: { $0.value < $1.value })?
                .key

            let canonical: EmailThread
            if let canonicalID, let existing = existingThreadByID[canonicalID] {
                canonical = existing
                claimedExistingThreadIDs.insert(canonicalID)
                // Absorb new messages into the reused thread by widening its
                // date window and refreshing its normalized subject (in case
                // the cluster boundary changed).
                canonical.firstDate = min(existing.firstDate, grouping.firstDate)
                canonical.lastDate = max(existing.lastDate, grouping.lastDate)
                canonical.subjectNormalized = grouping.subject
            } else {
                // Genuinely new cluster — none of its messages had a prior
                // thread (or all prior candidates were already claimed).
                let fresh = EmailThread(
                    subjectNormalized: grouping.subject,
                    messages: [],
                    firstDate: grouping.firstDate,
                    lastDate: grouping.lastDate
                )
                modelContext.insert(fresh)
                existingThreadByID[fresh.id] = fresh
                canonical = fresh
            }

            // Re-attach each visible message in the cluster to its canonical thread.
            for mid in grouping.messageIDs {
                if let email = messagesByID[mid] {
                    email.thread = canonical
                }
            }
        }

        // Delete prior threads that are now truly empty: their visible
        // messages moved on AND they have no archived/deleted stragglers
        // still attached (those would keep `thread.messages` non-empty and
        // the thread alive — correct, since we never touch them here).
        for (id, thread) in existingThreadByID where !claimedExistingThreadIDs.contains(id) {
            if thread.messages.isEmpty {
                modelContext.delete(thread)
            }
        }

        save()
    }

    // MARK: - Review selection

    /// Cap on the resurface-interval decay (in days). A thread reviewed `n`
    /// times without new activity becomes eligible again after
    /// `min(1 + n, maxResurfaceDays)` days — the `+1` brings a once-reviewed
    /// thread back after two days, and the cap means it never goes longer than
    /// a week without being re-offered for triage. So a thread loses urgency
    /// the more often it's been shown without action, but never escapes the
    /// inbox entirely (it always returns at least weekly).
    static let maxResurfaceDays = 7

    /// Weekly resurface cap in seconds, used by tests that check stale mail
    /// returns.
    static let reviewResurfaceInterval: TimeInterval = TimeInterval(maxResurfaceDays) * 86_400

    /// Per-thread resurface window in seconds, decayed by how many times the
    /// thread has already been reviewed without new activity.
    private static func resurfaceInterval(reviewedCount: Int) -> TimeInterval {
        let days = min(1 + max(0, reviewedCount), maxResurfaceDays)
        return TimeInterval(days) * 86_400
    }

    /// Selects the threads handed to the model for an inbox-review pass,
    /// according to `filter`. Replaces the old all-or-nothing pre-fetch: the
    /// model now drives selection through the `fetch_inbox_emails` tool, which
    /// builds the filter from its arguments.
    ///
    /// The pipeline, applied in Swift (the decay suppression and note-presence
    /// checks aren't expressible as a SwiftData predicate):
    /// 1. Candidate set — non-archived/non-deleted threads, widened to include
    ///    archived/trashed messages only when the matching include flag is set.
    /// 2. Suppression (when `filter.applySuppression`) — a just-reviewed thread
    ///    waits out its decayed window; flagged/notated threads bypass it.
    /// 3. Age window — threads whose latest activity predates `maxAgeDays` are
    ///    dropped, except flagged/notated ones (explicit "still matters"
    ///    markers that may legitimately point months out). The default filter
    ///    leaves this unbounded so stale read mail can resurface.
    /// 4. Category include/exclude — a thread is kept when it matches at least
    ///    one enabled category (flagged/notated/unread/read).
    /// 5. Limit with overrides — unread/flagged/notated threads are never
    ///    dropped by the limit; the cap only trims the remaining plain-read
    ///    threads. Sorted newest-first.
    func fetchThreadsForReview(
        filter: EmailReviewFetchFilter,
        now: Date = .now
    ) -> [EmailThread] {
        let candidates = fetchReviewCandidateThreads(
            includeArchived: filter.includeArchived,
            includeTrashed: filter.includeTrashed
        )

        let ageWindow = TimeInterval(max(0, filter.maxAgeDays)) * 86_400
        let ageCutoff = now.addingTimeInterval(-ageWindow)

        var overrides: [EmailThread] = []  // unread/flagged/notated — never capped
        var others: [EmailThread] = []     // plain read — subject to the limit

        for thread in candidates {
            let considered = Self.consideredMessages(of: thread, filter: filter)
            guard let latest = considered.last else { continue }

            let isFlagged = considered.contains { $0.isFlagged }
            let isNotated = considered.contains { !$0.notes.isEmpty }
            let isUnread = considered.contains { !$0.isRead }
            let isMarker = isFlagged || isNotated  // bypasses suppression + age

            if filter.applySuppression,
               !Self.passesSuppression(thread, isMarker: isMarker, now: now) {
                continue
            }

            // Flagged/notated threads are exempt from the age window; unread is
            // not (so an ancient unread backlog stays bounded by the window —
            // unread only overrides the count limit, below).
            if latest.date < ageCutoff && !isMarker {
                continue
            }

            let keep =
                (isFlagged && filter.includeFlagged) ||
                (isNotated && filter.includeNotated) ||
                (isUnread && filter.includeUnread) ||
                (!isUnread && filter.includeRead)
            guard keep else { continue }

            if isUnread || isMarker {
                overrides.append(thread)
            } else {
                others.append(thread)
            }
        }

        let remainingSlots = max(0, filter.limit - overrides.count)
        let selected = overrides + others.prefix(remainingSlots)
        return selected.sorted { $0.lastDate > $1.lastDate }
    }

    /// Test-only convenience over `fetchThreadsForReview`: no age cap, an
    /// optional hard count, suppression toggled by `force`. Production code
    /// builds an `EmailReviewFetchFilter` and calls `fetchThreadsForReview`
    /// directly (via the `fetch_inbox_emails` tool).
    func fetchNonArchivedThreadsForReview(
        limit: Int? = nil,
        force: Bool = false,
        now: Date = .now
    ) -> [EmailThread] {
        var filter = EmailReviewFetchFilter(applySuppression: !force)
        filter.maxAgeDays = Int.max          // no age cap (legacy behavior)
        filter.limit = limit ?? Int.max      // no count cap unless requested
        return fetchThreadsForReview(filter: filter, now: now)
    }

    /// Cheap gate for the scheduled loop: is any thread eligible under default
    /// suppression? Lets `EmailReviewService` skip the inference call entirely
    /// when everything has already been triaged since the last new mail —
    /// preserving the "don't call the model when there's nothing to do"
    /// optimization the inlined pre-fetch used to give for free.
    func hasThreadsEligibleForReview(now: Date = .now) -> Bool {
        let candidates = fetchReviewCandidateThreads(includeArchived: false, includeTrashed: false)
        return candidates.contains { thread in
            // Gate-level markers use reviewable messages only; the fetch path
            // recalculates them from the caller's include flags.
            Self.passesSuppression(
                thread,
                isMarker: thread.isReviewFlagged || thread.hasReviewNote,
                now: now
            )
        }
    }

    private func fetchReviewCandidateThreads(
        includeArchived: Bool,
        includeTrashed: Bool
    ) -> [EmailThread] {
        let descriptor = FetchDescriptor<EmailThread>(
            predicate: #Predicate { thread in
                thread.messages.contains { message in
                    (!message.isArchived && !message.isDeleted)
                        || (includeArchived && message.isArchived)
                        || (includeTrashed && message.isDeleted)
                }
            },
            sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// The messages of `thread` that count toward review under `filter`:
    /// inbox messages always, archived/trashed only when their include flag is
    /// set. Sorted oldest-first so `.last` is the latest considered message.
    private static func consideredMessages(
        of thread: EmailThread,
        filter: EmailReviewFetchFilter
    ) -> [Email] {
        thread.sortedMessages.filter { message in
            if message.isDeleted { return filter.includeTrashed }
            if message.isArchived { return filter.includeArchived }
            return true
        }
    }

    /// Whether a thread survives decay suppression. Flagged/notated threads
    /// (`isMarker`) always pass — the user's explicit "this still matters"
    /// signal, which the model re-judges each pass. Otherwise a thread passes
    /// when it's never been reviewed, has new mail since its last review, or
    /// was last reviewed longer ago than its decayed resurface window.
    private static func passesSuppression(
        _ thread: EmailThread,
        isMarker: Bool,
        now: Date
    ) -> Bool {
        if isMarker { return true }
        guard let lastReviewedAt = thread.lastReviewedAt else { return true }
        let latestMessageDate = thread.latestReviewableMessage?.date ?? .distantPast
        if lastReviewedAt < latestMessageDate { return true }  // new mail
        let cutoff = now.addingTimeInterval(-resurfaceInterval(reviewedCount: thread.reviewedCount))
        return lastReviewedAt < cutoff
    }

    /// Stamps a batch of threads as reviewed at the given timestamp, then saves
    /// once. Called by `EmailReviewService` per pass AFTER a successful
    /// inference run, so a transient failure doesn't permanently suppress the
    /// threads that were supposed to be triaged.
    ///
    /// Also advances the resurface-decay counter: fresh activity (new mail
    /// since the last review, or a never-reviewed thread) restarts the decay at
    /// 1 — so the thread resurfaces after two days, like a first review.
    /// Otherwise the count climbs and the resurface window widens toward the
    /// weekly cap, letting an untouched thread lose urgency without escaping.
    func markThreadsReviewed(_ threads: [EmailThread], at date: Date = .now) {
        guard !threads.isEmpty else { return }
        for thread in threads {
            let latestMessageDate = thread.latestReviewableMessage?.date ?? .distantPast
            let hadFreshActivity = thread.lastReviewedAt.map { $0 < latestMessageDate } ?? true
            thread.reviewedCount = hadFreshActivity ? 1 : thread.reviewedCount + 1
            thread.lastReviewedAt = date
        }
        save()
    }

    /// Loads threads by ID so a caller holding only IDs (e.g. the IDs the
    /// `fetch_inbox_emails` tool returned from a separate context) can mark them
    /// reviewed in this repository's context.
    func fetchThreads(withIDs ids: [UUID]) -> [EmailThread] {
        guard !ids.isEmpty else { return [] }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<EmailThread>(
            predicate: #Predicate { idSet.contains($0.id) }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Total count of inbox threads (non-archived, non-deleted). Used by
    /// `EmailReviewService` to distinguish "all threads already triaged
    /// since last new mail" (H3 suppression path — expected) from "inbox
    /// genuinely has nothing to review" in its skip log, so the log doesn't
    /// read like the prior pass produced nothing.
    func fetchNonArchivedThreadCount() -> Int {
        let descriptor = FetchDescriptor<EmailThread>(
            predicate: #Predicate { thread in
                thread.messages.contains { message in
                    !message.isArchived && !message.isDeleted
                }
            }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func fetchEmail(by id: UUID) -> Email? {
        var descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Sent-message ingestion

    /// Locally records a just-sent reply so it shows up immediately in the
    /// thread detail (and threads via `In-Reply-To`/`References`) without
    /// waiting for the next Sent-folder sync.
    ///
    /// The row gets a *local-only* uid synthesized as `max(existing uid in
    /// this mailbox+account) + 1` (clamped below `Int.max - 1`). That's
    /// collision-free among locally-sent messages and stays out of the real
    /// IMAP UID range. The
    /// `isLocallySynthetic` flag marks the row as client-seeded.
    ///
    /// When a real Sent-folder sync lands the matching message (deduped by
    /// `messageID` in `upsertMessages`), the synthetic row is *promoted* —
    /// its `uid` is rewritten to the real server uid + `isLocallySynthetic`
    /// is cleared — so the final state has one row, not two. Sent-mailbox
    /// deletion reconciliation (`reconcileDeletions`) preserves synthetic
    /// rows by skipping any row still flagged `isLocallySynthetic`.
    ///
    /// Idempotent on `OutgoingEmail.messageID`: if a local row already
    /// exists for the same `(accountID, sentMailbox, messageID)` triple the
    /// call is a no-op (handles duplicate Sends and a future re-ingest
    /// after APPEND already wrote a copy).
    @discardableResult
    func upsertSentMessage(
        _ outgoing: OutgoingEmail,
        account: StoredEmailAccount,
        sentMailbox: String
    ) -> Email? {
        if let messageID = outgoing.messageID, !messageID.isEmpty {
            let existing = FetchDescriptor<Email>(
                predicate: #Predicate { email in
                    email.mailbox == sentMailbox
                        && email.accountID == account.id
                        && email.messageID == messageID
                }
            )
            if let already = try? modelContext.fetch(existing), !already.isEmpty {
                return already.first
            }
        }

        let maxExistingUID = (try? modelContext.fetch(
            FetchDescriptor<Email>(
                predicate: #Predicate { email in
                    email.mailbox == sentMailbox && email.accountID == account.id
                }
            )
        ))?.map(\.uid).max() ?? 0
        let syntheticUID = min(maxExistingUID + 1, Int.max - 1)

        let sent = Email(
            messageID: outgoing.messageID,
            subject: outgoing.subject,
            fromAddress: outgoing.fromAddress,
            toAddresses: outgoing.toAddresses,
            ccAddresses: outgoing.ccAddresses,
            bccAddresses: outgoing.bccAddresses,
            date: .now,
            receivedAt: .now,
            bodyText: outgoing.bodyText,
            bodyHTML: outgoing.bodyHTML,
            mailbox: sentMailbox,
            isRead: true,
            isFlagged: false,
            isArchived: false,
            isDeleted: false,
            inReplyTo: outgoing.inReplyTo,
            referencesRaw: outgoing.references,
            accountID: account.id,
            uid: syntheticUID
        )
        sent.isLocallySynthetic = true
        modelContext.insert(sent)
        resolveThreads()
        return sent
    }

    // MARK: - Deletion + flag reconciliation

    /// Reconciles the local store against the server's current mailbox
    /// membership: soft-deletes (`isDeleted = true`) any local row whose UID
    /// is no longer present on the server. Saves once and returns the count
    /// of rows newly soft-deleted.
    ///
    /// Preserves SwiftClaw-owned metadata by **soft-deleting only** — the
    /// `Email` row, its `EmailNote`s, `EmailThread` linkage, `lastReviewedAt`
    /// stamp, and local-only `isArchived`/`isFlagged` overrides stay intact
    /// on the moved-to-Trash row. The explicit "Delete Permanently"
    /// affordance in the Trash mailbox owns hard-delete; the
    /// `EmailNote` cascade rule means a hard-delete here would destroy
    /// user-authored notes, which is exactly why we don't.
    ///
    /// Rows the user explicitly archived (`isArchived = true`) are NOT
    /// touched — they're already filed out of Inbox and their server-side
    /// absence is expected. Reconciliation only retires rows that are still
    /// active (`!isArchived && !isDeleted`). New mail that just arrived in
    /// this same sync pass is already upserted before this runs, so it's
    /// present in `serverUIDs` and stays active.
    ///
    /// Scope: per `(mailbox, accountID)`. Multi-mailbox sync calls this per
    /// synced mailbox, taking care to skip the locally-synthetic Sent UIDs
    /// that `upsertSentMessage` produces (those won't be in the server set
    /// until the provider's Sent APPEND has landed).
    @discardableResult
    func reconcileDeletions(
        serverUIDs: Set<UInt32>,
        mailbox: String,
        accountID: UUID,
        preserveLocallySynthetic: Bool = false
    ) -> Int {
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
                    && !email.isArchived
                    && !email.isDeleted
            }
        )
        guard let locals = try? modelContext.fetch(descriptor), !locals.isEmpty else {
            return 0
        }
        var removed = 0
        for email in locals where !serverUIDs.contains(UInt32(email.uid)) {
            // Skip locally-synthetic Sent rows — they're client-seeded echoes
            // of just-sent replies that the server has no record of yet.
            // The next Sent-folder sync reconciles them by `messageID`
            // (see `upsertSentMessage`). Only the Sent-mailbox pass passes
            // `preserveLocallySynthetic: true`.
            if preserveLocallySynthetic && email.isLocallySynthetic { continue }
            email.isDeleted = true
            removed += 1
        }
        if removed > 0 {
            save()
        }
        return removed
    }

    /// Refreshes `\Seen`/`\Flagged` on messages that already exist locally
    /// but whose flags changed on the server from another client. Closes the
    /// H2 flag-drift gap: under incremental sync, `reconcileFlags(existing:)`
    /// only fires when a message is *re-fetched* (new mail), so flag changes
    /// on persisting rows stayed stale until the next full mailbox re-fetch.
    /// The `MailboxUIDSet` comes from the same cheap `.uidFlagsOnly` scan the
    /// deletion pass uses — no extra round-trip. Saves once and returns the
    /// count of rows whose flags actually changed.
    @discardableResult
    func reconcileFlagsFromSnapshot(
        _ snapshot: MailboxUIDSet,
        mailbox: String,
        accountID: UUID
    ) -> Int {
        guard !snapshot.flagsByUID.isEmpty else { return 0 }
        // `#Predicate` can't call `UInt32(...)` initializers, so fetch by
        // mailbox+account and filter-by-UID in Swift (small per-call set).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
            }
        )
        guard let locals = try? modelContext.fetch(descriptor), !locals.isEmpty else {
            return 0
        }
        var changed = 0
        for email in locals {
            guard let snap = snapshot.flagsByUID[UInt32(email.uid)] else { continue }
            // Don't clobber a local flag/read change that hasn't synced yet —
            // the snapshot predates it. `EmailServerAction` clears the marker
            // once the server confirms, releasing the row to refresh again.
            if email.needsFlagSync { continue }
            if email.isRead != snap.isRead {
                email.isRead = snap.isRead
                changed += 1
            }
            if email.isFlagged != snap.isFlagged {
                email.isFlagged = snap.isFlagged
                changed += 1
            }
        }
        if changed > 0 {
            save()
        }
        return changed
    }

    // MARK: - Internals

    private func fetchExistingMailboxIndex(uids: [Int], mailbox: String, accountID: UUID) -> [Int: Email] {
        guard !uids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && uids.contains(email.uid)
                    && email.accountID == accountID
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: results.map { ($0.uid, $0) })
    }

    /// Indexes existing rows by `messageID` for a single `(mailbox, accountID)`.
    /// Used by `upsertMessages`'s synthetic-row promotion path — see
    /// `upsertSentMessage` for the full lifecycle.
    private func fetchExistingByMessageID(
        messageIDs: [String],
        mailbox: String,
        accountID: UUID
    ) -> [String: Email] {
        guard !messageIDs.isEmpty else { return [:] }
        // Fetch the mailbox+account slice; `#Predicate` can't call
        // `UInt32(...)` initializers or thread `?? ""` through `contains`,
        // so filter by `messageID` in Swift (small per-call Sent slice).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.mailbox == mailbox
                    && email.accountID == accountID
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        let messageIDSet = Set(messageIDs)
        // First-wins on duplicate messageIDs (the synthetic-then-real
        // transition is the only expected duplicate; preferring either is
        // fine since the caller rewrites the synthetic's uid + marker).
        return Dictionary(
            results.compactMap { email in
                guard let mid = email.messageID, !mid.isEmpty, messageIDSet.contains(mid) else {
                    return nil
                }
                return (mid, email)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Indexes rows that a server-side archive should reclaim: an active INBOX
    /// row (or one the deletion pass just soft-deleted this sync) that shares a
    /// `messageID` with a message now arriving in the Archive folder. Scoped to
    /// one account and keyed by `messageID`. Excludes locally-synthetic Sent
    /// echoes and anything already filed in the Archive mailbox, so only a
    /// genuine "left INBOX → now in Archive" move reclaims its row.
    private func fetchArchiveReclaimCandidates(
        messageIDs: [String],
        archiveMailbox: String,
        accountID: UUID
    ) -> [String: Email] {
        guard !messageIDs.isEmpty else { return [:] }
        // `#Predicate` can't thread `messageID ?? ""` through `contains`, so
        // narrow to the account's INBOX + soft-deleted rows and match the
        // `messageID` in Swift (a small per-call set).
        let descriptor = FetchDescriptor<Email>(
            predicate: #Predicate { email in
                email.accountID == accountID
                    && email.mailbox != archiveMailbox
                    && !email.isLocallySynthetic
                    && (email.mailbox == "INBOX" || email.isDeleted)
            }
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            return [:]
        }
        let messageIDSet = Set(messageIDs)
        return Dictionary(
            results.compactMap { email in
                guard let mid = email.messageID, !mid.isEmpty, messageIDSet.contains(mid) else {
                    return nil
                }
                return (mid, email)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func insert(
        message: FetchedMessage,
        mailbox: String,
        accountID: UUID,
        isDeletedMailbox: Bool,
        isArchiveMailbox: Bool = false
    ) {
        let email = Email(
            messageID: message.messageID,
            subject: message.subject,
            fromAddress: message.fromAddress,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            bccAddresses: message.bccAddresses,
            date: message.date,
            receivedAt: message.internalDate ?? message.date,
            bodyText: message.bodyText,
            bodyHTML: message.bodyHTML,
            mailbox: mailbox,
            isRead: message.isRead,
            isFlagged: message.isFlagged,
            isArchived: isArchiveMailbox,
            isDeleted: isDeletedMailbox,
            inReplyTo: message.inReplyTo,
            referencesRaw: message.references,
            accountID: accountID,
            uid: message.uid
        )

        for descriptor in message.attachmentDescriptors {
            // Persist attachment bytes to disk when the fetch path supplied
            // them (the `fetchMailbox` full-body fetch already pulled them
            // — no extra round-trip). Metadata-only scans (the `.uidFlagsOnly`
            // reconciliation pass) never reach `insert`, so there's no
            // wasted write here. Falls back to `filePath == ""` when bytes
            // weren't supplied; the viewer then renders the row as
            // "unavailable" without a file URL.
            var filePath = ""
            if let data = descriptor.data, !data.isEmpty {
                filePath = (try? EmailAttachmentStore.shared.save(
                    data: data,
                    filename: descriptor.filename,
                    forEmailID: email.id
                )) ?? ""
            }
            let attachment = EmailAttachment(
                filename: descriptor.filename,
                filePath: filePath,
                mimeType: descriptor.mimeType,
                sizeBytes: descriptor.sizeBytes
            )
            attachment.email = email
            email.attachments.append(attachment)
        }

        modelContext.insert(email)
    }

    private func reconcileFlags(existing: Email, fetched: FetchedMessage) {
        existing.isRead = fetched.isRead
        existing.isFlagged = fetched.isFlagged
        // Refresh body in case server-side edits happened.
        if existing.bodyText.isEmpty, !fetched.bodyText.isEmpty {
            existing.bodyText = fetched.bodyText
        }
        if existing.bodyHTML == nil, let html = fetched.bodyHTML {
            existing.bodyHTML = html
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("EmailRepository save failed: \(String(describing: error))")
        }
    }
}
