import Foundation
import SwiftData

/// Review-selection queries + resurface-decay suppression. Extracted from
/// `EmailRepository` so the core file stays focused on upsert/flag/thread
/// mutations; the model-driven review path (`EmailReviewFetchTool` /
/// `EmailReviewService`) is the sole consumer.
extension EmailRepository {

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
        let ageWindow = TimeInterval(max(0, filter.maxAgeDays)) * 86_400
        let ageCutoff = now.addingTimeInterval(-ageWindow)
        var overrides: [EmailThread] = []  // unread/flagged/notated — never capped
        var others: [EmailThread] = []     // plain read — subject to the limit

        func classify(_ thread: EmailThread) {
            let considered = Self.consideredMessages(of: thread, filter: filter)
            guard let latest = considered.last else { return }

            let isFlagged = considered.contains { $0.isFlagged }
            let isNotated = considered.contains { !$0.notes.isEmpty }
            let isUnread = considered.contains { !$0.isRead }
            let isMarker = isFlagged || isNotated  // bypasses suppression + age

            if filter.applySuppression,
               !Self.passesSuppression(thread, isMarker: isMarker, now: now) {
                return
            }

            // Flagged/notated threads are exempt from the age window; unread is
            // not (so an ancient unread backlog stays bounded by the window —
            // unread only overrides the count limit, below).
            if latest.date < ageCutoff && !isMarker {
                return
            }

            let keep =
                (isFlagged && filter.includeFlagged) ||
                (isNotated && filter.includeNotated) ||
                (isUnread && filter.includeUnread) ||
                (!isUnread && filter.includeRead)
            guard keep else { return }

            if isUnread || isMarker {
                overrides.append(thread)
            } else {
                others.append(thread)
            }
        }

        let notatedThreads = fetchNotatedReviewThreads()
        let notatedThreadIDs = Set(notatedThreads.map(\.id))
        var broadOverrides = fetchReviewCandidateThreads(overrideCategory: true, filter: filter)
        let fetchedOverrideIDs = Set(broadOverrides.map(\.id))
        broadOverrides.append(contentsOf: notatedThreads.filter { !fetchedOverrideIDs.contains($0.id) })

        // Broad model-level override rows stay uncapped. The precise
        // folder/category checks still happen above; a thread whose marker is
        // only in an excluded folder is correctly reclassified as ordinary.
        for thread in broadOverrides {
            classify(thread)
        }

        if filter.limit == Int.max {
            for thread in fetchReviewCandidateThreads(
                overrideCategory: false,
                filter: filter,
                excludingThreadIDs: notatedThreadIDs
            ) {
                classify(thread)
            }
        } else if filter.limit > 0 {
            // Filtering includes suppression and custom-folder rules that
            // SwiftData cannot express. Page with a fetchLimit until enough
            // eligible ordinary rows are found; this preserves the exact cap
            // without eagerly materializing the whole ordinary candidate set.
            let pageSize = max(1, filter.limit)
            var offset = 0
            var eligibleFromOrdinaryQuery = 0
            while eligibleFromOrdinaryQuery < filter.limit {
                let page = fetchReviewCandidateThreads(
                    overrideCategory: false,
                    filter: filter,
                    excludingThreadIDs: notatedThreadIDs,
                    fetchLimit: pageSize,
                    fetchOffset: offset
                )
                guard !page.isEmpty else { break }
                let priorCount = others.count
                for thread in page { classify(thread) }
                eligibleFromOrdinaryQuery += others.count - priorCount
                offset += page.count
                if page.count < pageSize { break }
            }
        }

        let remainingSlots = max(0, filter.limit - overrides.count)
        let selected = overrides + others
            .sorted { $0.lastDate > $1.lastDate }
            .prefix(remainingSlots)
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
        hasThreadsEligibleForReview(filter: EmailReviewFetchFilter(), now: now)
    }

    func hasThreadsEligibleForReview(filter: EmailReviewFetchFilter, now: Date = .now) -> Bool {
        let candidates = fetchReviewCandidateThreads(
            includeArchived: filter.includeArchived,
            includeTrashed: filter.includeTrashed,
            folders: filter.folders
        )
        return candidates.contains { thread in
            let considered = Self.consideredMessages(of: thread, filter: filter)
            guard !considered.isEmpty else { return false }
            let isMarker = considered.contains { $0.isFlagged || !$0.notes.isEmpty }
            return Self.passesSuppression(
                thread,
                isMarker: isMarker,
                now: now
            )
        }
    }

    private func fetchReviewCandidateThreads(
        overrideCategory: Bool,
        filter: EmailReviewFetchFilter,
        excludingThreadIDs: Set<UUID> = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int = 0
    ) -> [EmailThread] {
        // Archived/trashed visibility must live in the predicate, not in
        // `classify`: threads materialized through relationship-predicate
        // fetches can serve stale attribute snapshots, so an in-memory
        // recheck is not a reliable exclusion boundary.
        let includeArchived = filter.includeArchived
        let includeTrashed = filter.includeTrashed
        let foldersRequested = !(filter.folders ?? []).isEmpty
        var descriptor: FetchDescriptor<EmailThread>
        if foldersRequested {
            // Explicitly requested folders always count, even archived or
            // trashed (matching `consideredMessages`) — folder names aren't
            // predicate-expressible, so keep only the category split and let
            // `classify` apply the folder rules.
            if overrideCategory {
                descriptor = FetchDescriptor<EmailThread>(
                    predicate: #Predicate { thread in
                        thread.messages.contains { message in
                            !message.isRead || message.isFlagged
                        }
                    },
                    sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
                )
            } else {
                descriptor = FetchDescriptor<EmailThread>(
                    predicate: #Predicate { thread in
                        !excludingThreadIDs.contains(thread.id)
                            && !thread.messages.contains { message in
                                !message.isRead || message.isFlagged
                            }
                    },
                    sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
                )
            }
        } else if overrideCategory {
            descriptor = FetchDescriptor<EmailThread>(
                predicate: #Predicate { thread in
                    thread.messages.contains { message in
                        ((!message.isArchived && !message.isTrashed)
                            || (includeArchived && message.isArchived)
                            || (includeTrashed && message.isTrashed))
                            && (!message.isRead || message.isFlagged)
                    }
                },
                sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<EmailThread>(
                predicate: #Predicate { thread in
                    !excludingThreadIDs.contains(thread.id)
                        && thread.messages.contains { message in
                            (!message.isArchived && !message.isTrashed)
                                || (includeArchived && message.isArchived)
                                || (includeTrashed && message.isTrashed)
                        }
                        && !thread.messages.contains { message in
                            ((!message.isArchived && !message.isTrashed)
                                || (includeArchived && message.isArchived)
                                || (includeTrashed && message.isTrashed))
                                && (!message.isRead || message.isFlagged)
                        }
                },
                sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
            )
        }
        if let fetchLimit { descriptor.fetchLimit = fetchLimit }
        descriptor.fetchOffset = fetchOffset
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchNotatedReviewThreads() -> [EmailThread] {
        let notes = (try? modelContext.fetch(FetchDescriptor<EmailNote>())) ?? []
        var seen: Set<UUID> = []
        return notes.compactMap { note in
            guard let thread = note.email?.thread,
                  seen.insert(thread.id).inserted else {
                return nil
            }
            return thread
        }
    }

    private func fetchReviewCandidateThreads(
        includeArchived: Bool,
        includeTrashed: Bool,
        folders: [String]? = nil
    ) -> [EmailThread] {
        if !(folders ?? []).isEmpty {
            let descriptor = FetchDescriptor<EmailThread>(
                sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
            )
            return (try? modelContext.fetch(descriptor)) ?? []
        }

        let descriptor = FetchDescriptor<EmailThread>(
            predicate: #Predicate { thread in
                thread.messages.contains { message in
                    (!message.isArchived && !message.isTrashed)
                        || (includeArchived && message.isArchived)
                        || (includeTrashed && message.isTrashed)
                }
            },
            sortBy: [SortDescriptor(\.lastDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// The messages of `thread` that count toward review under `filter`:
    /// explicitly requested folders always; otherwise archived/trashed only
    /// when their include flag is set, and the rest per role eligibility
    /// (inbox/sent always, opted-in custom folders, never junk/drafts).
    /// Sorted oldest-first so `.last` is the latest considered message. Also
    /// the message set `EmailReviewThreadDescriptor` serializes, so selection
    /// and payload share one folder scope.
    static func consideredMessages(
        of thread: EmailThread,
        filter: EmailReviewFetchFilter
    ) -> [Email] {
        let explicitFolders = filter.normalizedFolders
        return thread.sortedMessages.filter { message in
            let mailbox = EmailReviewFetchFilter.normalizeFolderName(message.mailbox)
            let explicitlyRequested = explicitFolders.contains(mailbox)
            if explicitlyRequested {
                return true
            }
            if message.isTrashed {
                return filter.includeTrashed
            }
            if message.isArchived {
                return filter.includeArchived
            }
            return isMessageReviewEligible(message, filter: filter)
        }
    }

    private static func isMessageReviewEligible(_ message: Email, filter: EmailReviewFetchFilter) -> Bool {
        switch message.role {
        case .inbox, .sent:
            return true
        case .custom:
            let mailbox = EmailReviewFetchFilter.normalizeFolderName(message.mailbox)
            return filter.includedCustomFoldersByAccount[message.accountID]?.contains(mailbox) == true
        case .junk, .drafts:
            return false
        case .archive:
            return filter.includeArchived
        case .trash:
            return filter.includeTrashed
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
                    !message.isArchived && !message.isTrashed
                }
            }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}
