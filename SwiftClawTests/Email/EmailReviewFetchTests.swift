import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Tests for the model-driven inbox selection introduced with the
/// `fetch_inbox_emails` tool: the `reviewedCount` resurface-decay, the
/// filter-based `EmailRepository.fetchThreadsForReview`, and the tool itself.
@MainActor
struct EmailReviewFetchTests {
    private static let accountID = UUID()

    // Collects the thread IDs the fetch tool reports, mirroring how
    // `EmailReviewService` accumulates them. A MainActor reference type so the
    // tool's `@MainActor` callback can mutate the same instance the test reads.
    @MainActor
    private final class FetchedIDBox {
        private(set) var ids: [UUID] = []
        func add(_ newIDs: [UUID]) { ids.append(contentsOf: newIDs) }
    }

    private func suppressionOnlyFilter() -> EmailReviewFetchFilter {
        var filter = EmailReviewFetchFilter(applySuppression: true)
        filter.maxAgeDays = 36_500   // effectively no age cap (~100y)
        filter.limit = .max          // no count cap
        return filter
    }

    // MARK: - reviewedCount decay

    @Test func resurfaceWindowGrowsWithReviewCount() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))

        let base = Date()
        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<decay@example.com>", subject: "Read backlog",
            isRead: true, date: base.addingTimeInterval(-3_600)
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()
        let filter = suppressionOnlyFilter()

        // First review: never-reviewed → eligible. Stamp sets reviewedCount = 1
        // (fresh activity), so the window is 2 days.
        let first = repository.fetchThreadsForReview(filter: filter, now: base)
        #expect(first.count == 1)
        repository.markThreadsReviewed(first, at: base)
        #expect(first.first?.reviewedCount == 1)

        let day: TimeInterval = 86_400
        // 1 day later: inside the 2-day window → suppressed.
        #expect(repository.fetchThreadsForReview(filter: filter, now: base + day).isEmpty)
        // Just past 2 days → resurfaces.
        let resurface = repository.fetchThreadsForReview(filter: filter, now: base + 2 * day + 60)
        #expect(resurface.count == 1)

        // Review again with no new mail → reviewedCount climbs to 2, window 3 days.
        let secondReviewTime = base + 2 * day + 60
        repository.markThreadsReviewed(resurface, at: secondReviewTime)
        #expect(resurface.first?.reviewedCount == 2)
        // 2 days after the second review: inside the now-3-day window → suppressed.
        #expect(repository.fetchThreadsForReview(filter: filter, now: secondReviewTime + 2 * day).isEmpty)
        // Past 3 days → resurfaces again.
        #expect(repository.fetchThreadsForReview(filter: filter, now: secondReviewTime + 3 * day + 60).count == 1)
    }

    @Test func resurfaceWindowCapsAtMaxResurfaceDays() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let base = Date()
        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<cap@example.com>", subject: "Long backlog",
            isRead: true, date: base.addingTimeInterval(-3_600)
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        // Simulate a thread shown many times: the decay is capped at 7 days.
        let thread = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first)
        thread.reviewedCount = 25
        thread.lastReviewedAt = base
        try context.save()

        let filter = suppressionOnlyFilter()
        let day: TimeInterval = 86_400
        // 6 days out: still inside the capped 7-day window → suppressed.
        #expect(repository.fetchThreadsForReview(filter: filter, now: base + 6 * day).isEmpty)
        // Past 7 days → resurfaces despite the high count (never escapes).
        #expect(repository.fetchThreadsForReview(filter: filter, now: base + 7 * day + 60).count == 1)
    }

    @Test func newMailResetsDecayCounter() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let base = Date()
        let original = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<reset@example.com>", subject: "Conversation",
            isRead: true, date: base.addingTimeInterval(-3_600)
        )
        repository.upsertMessages([original], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        // Drive the count up with two no-new-mail reviews (1 then 2).
        let thread = try #require(try context.fetch(FetchDescriptor<EmailThread>()).first)
        repository.markThreadsReviewed([thread], at: base)
        repository.markThreadsReviewed([thread], at: base.addingTimeInterval(10 * 86_400))
        #expect(thread.reviewedCount == 2)

        // New mail lands (dated after the last review). The next stamp treats it
        // as fresh activity and restarts the decay at 1.
        let reply = FetchedMessage(
            uid: 2, messageID: "<reset-reply@example.com>", subject: "Re: Conversation",
            fromAddress: "sender@example.com", toAddresses: ["me@example.com"],
            ccAddresses: [], bccAddresses: [],
            date: base.addingTimeInterval(20 * 86_400), internalDate: base.addingTimeInterval(20 * 86_400),
            bodyText: "Fresh", bodyHTML: nil, inReplyTo: "<reset@example.com>",
            references: ["<reset@example.com>"], isRead: false, isFlagged: false,
            mailbox: "INBOX", attachmentDescriptors: []
        )
        repository.upsertMessages([reply], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        repository.markThreadsReviewed([thread], at: base.addingTimeInterval(21 * 86_400))
        #expect(thread.reviewedCount == 1)
    }

    // MARK: - Filters

    @Test func unreadThreadsOverrideTheLimit() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))

        for index in 1...5 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index, messageID: "<unread-\(index)@example.com>", subject: "Unread \(index)"
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
            repository.resolveThreads()
        }

        // Five unread threads, limit 2 — unread overrides the cap, so all return.
        var filter = EmailReviewFetchFilter(applySuppression: false)
        filter.limit = 2
        #expect(repository.fetchThreadsForReview(filter: filter).count == 5)
    }

    @Test func readThreadsRespectTheLimit() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))

        for index in 1...5 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index, messageID: "<read-\(index)@example.com>", subject: "Read \(index)",
                isRead: true, date: Date().addingTimeInterval(TimeInterval(-index))
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
            repository.resolveThreads()
        }

        // Plain read threads are not overrides — the limit caps them.
        var filter = EmailReviewFetchFilter(applySuppression: false)
        filter.limit = 2
        #expect(repository.fetchThreadsForReview(filter: filter).count == 2)
    }

    @Test func ordinaryFetchPagesPastSuppressedNewerThreads() throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let now = Date()
        repository.upsertMessages(
            [
                EmailRepositoryTests.simpleMessage(
                    uid: 1,
                    messageID: "<older-eligible@example.com>",
                    subject: "Older eligible",
                    isRead: true,
                    date: now.addingTimeInterval(-60)
                ),
                EmailRepositoryTests.simpleMessage(
                    uid: 2,
                    messageID: "<newer-suppressed@example.com>",
                    subject: "Newer suppressed",
                    isRead: true,
                    date: now
                ),
            ],
            mailbox: "INBOX",
            accountID: Self.accountID
        )
        repository.resolveThreads()
        let newer = try #require(
            try context.fetch(FetchDescriptor<EmailThread>()).first {
                $0.latestMessage?.subject == "Newer suppressed"
            }
        )
        repository.markThreadsReviewed([newer], at: now)

        var filter = EmailReviewFetchFilter(applySuppression: true)
        filter.limit = 1
        let result = repository.fetchThreadsForReview(filter: filter, now: now)

        #expect(result.count == 1)
        #expect(result.first?.latestMessage?.subject == "Older eligible")
    }

    @Test func ageWindowExcludesOldReadMailButNotMarkers() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let recent = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<recent@example.com>", subject: "Recent read",
            isRead: true, date: Date().addingTimeInterval(-2 * 86_400)
        )
        let old = EmailRepositoryTests.simpleMessage(
            uid: 2, messageID: "<old@example.com>", subject: "Old read",
            isRead: true, date: Date().addingTimeInterval(-30 * 86_400)
        )
        let oldFlagged = EmailRepositoryTests.simpleMessage(
            uid: 3, messageID: "<old-flagged@example.com>", subject: "Old flagged",
            isRead: true, date: Date().addingTimeInterval(-60 * 86_400)
        )
        repository.upsertMessages([recent, old, oldFlagged], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()
        let flaggedEmail = try #require(try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 3 })
        _ = repository.setFlag(messageID: flaggedEmail.id, isFlagged: true)

        var filter = EmailReviewFetchFilter(applySuppression: false)
        filter.maxAgeDays = 7
        let result = repository.fetchThreadsForReview(filter: filter)
        let subjects = Set(result.compactMap { $0.latestReviewableMessage?.subject })
        // Recent read is in window; old read is excluded; old flagged is exempt.
        #expect(subjects.contains("Recent read"))
        #expect(!subjects.contains("Old read"))
        #expect(subjects.contains("Old flagged"))
    }

    @Test func defaultReviewFetchIncludesOldEligibleReadMail() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        let now = Date()

        let oldRead = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<old-default@example.com>", subject: "Old default read",
            isRead: true, date: now.addingTimeInterval(-30 * 86_400)
        )
        repository.upsertMessages([oldRead], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        let filter = EmailReviewFetchFilter(applySuppression: true)
        #expect(repository.hasThreadsEligibleForReview(now: now))
        let result = repository.fetchThreadsForReview(filter: filter, now: now)
        #expect(result.count == 1)
        #expect(result.first?.latestReviewableMessage?.subject == "Old default read")
    }

    @Test func archivedAndTrashedExcludedByDefaultIncludedOnRequest() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let archivedMsg = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<arch@example.com>", subject: "Archived thread", isRead: true
        )
        let trashedMsg = EmailRepositoryTests.simpleMessage(
            uid: 2, messageID: "<trash@example.com>", subject: "Trashed thread", isRead: true
        )
        repository.upsertMessages([archivedMsg, trashedMsg], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()
        let archivedEmail = try #require(try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 1 })
        repository.archive(messageID: archivedEmail.id)
        let trashedEmail = try #require(try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 2 })
        repository.delete(messageID: trashedEmail.id)

        // Default filter: neither archived nor trashed threads are candidates.
        let defaults = EmailReviewFetchFilter(applySuppression: false)
        #expect(repository.fetchThreadsForReview(filter: defaults).isEmpty)

        var includeArchived = EmailReviewFetchFilter(applySuppression: false)
        includeArchived.includeArchived = true
        #expect(repository.fetchThreadsForReview(filter: includeArchived).count == 1)

        var includeTrashed = EmailReviewFetchFilter(applySuppression: false)
        includeTrashed.includeTrashed = true
        #expect(repository.fetchThreadsForReview(filter: includeTrashed).count == 1)
    }

    @Test func customFoldersAreExcludedUnlessIncludedForScheduledReview() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<custom@example.com>", subject: "Custom folder")],
            mailbox: "Projects",
            accountID: Self.accountID,
            role: .custom
        )
        repository.resolveThreads()

        var filter = EmailReviewFetchFilter(applySuppression: false)
        #expect(repository.fetchThreadsForReview(filter: filter).isEmpty)
        #expect(repository.hasThreadsEligibleForReview(filter: filter) == false)

        filter.includedCustomFoldersByAccount = [
            Self.accountID: [EmailReviewFetchFilter.normalizeFolderName("Projects")]
        ]
        #expect(repository.fetchThreadsForReview(filter: filter).count == 1)
        #expect(repository.hasThreadsEligibleForReview(filter: filter))
    }

    @Test func explicitFoldersReachJunkEvenWhenNotScheduled() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<junk@example.com>", subject: "Junk folder")],
            mailbox: "Spam",
            accountID: Self.accountID,
            role: .junk
        )
        repository.resolveThreads()

        var defaults = EmailReviewFetchFilter(applySuppression: false)
        #expect(repository.fetchThreadsForReview(filter: defaults).isEmpty)

        defaults.folders = ["spam"]
        let fetched = repository.fetchThreadsForReview(filter: defaults)
        #expect(fetched.count == 1)
        #expect(fetched.first?.latestMessage?.subject == "Junk folder")
    }

    @Test func eligibilityGateReflectsSuppression() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<gate@example.com>", subject: "Gate", isRead: true
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
        repository.resolveThreads()

        #expect(repository.hasThreadsEligibleForReview())
        let fetched = repository.fetchNonArchivedThreadsForReview()
        repository.markThreadsReviewed(fetched, at: .now)
        // Just reviewed, no new mail → gate reports nothing eligible.
        #expect(repository.hasThreadsEligibleForReview() == false)
    }

    // MARK: - EmailReviewFetchTool

    @Test func fetchToolReturnsThreadJSONAndCollectsIDs() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        for index in 1...2 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index, messageID: "<tool-\(index)@example.com>", subject: "Tool \(index)"
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
            repository.resolveThreads()
        }

        let box = FetchedIDBox()
        let tool = EmailReviewFetchTool(
            modelContainer: container,
            applySuppression: false,
            defaults: Self.fetchDefaults(limit: 10),
            onThreadsFetched: { [box] ids in box.add(ids) }
        )

        let result = try await tool.execute(arguments: [:])
        let threadIDCount = result.components(separatedBy: "\"threadID\"").count - 1
        #expect(threadIDCount == 2)
        #expect(box.ids.count == 2)
    }

    @Test func fetchToolOnlyUnreadExcludesReadThreads() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<u@example.com>", subject: "Unread one")],
            mailbox: "INBOX", accountID: Self.accountID
        )
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 2, messageID: "<r@example.com>", subject: "Read one", isRead: true)],
            mailbox: "INBOX", accountID: Self.accountID
        )
        repository.resolveThreads()

        let tool = EmailReviewFetchTool(
            modelContainer: container,
            applySuppression: false,
            defaults: Self.fetchDefaults(limit: 10)
        )
        let result = try await tool.execute(arguments: ["include_read": .bool(false)])
        #expect(result.contains("Unread one"))
        #expect(!result.contains("Read one"))
    }

    @Test func fetchToolAppliesDefaultLimitToReadThreads() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        for index in 1...6 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index, messageID: "<dl-\(index)@example.com>", subject: "DL \(index)",
                isRead: true, date: Date().addingTimeInterval(TimeInterval(-index))
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: Self.accountID)
            repository.resolveThreads()
        }

        let tool = EmailReviewFetchTool(
            modelContainer: container,
            applySuppression: false,
            defaults: Self.fetchDefaults(limit: 3)
        )
        let result = try await tool.execute(arguments: [:])
        #expect(result.components(separatedBy: "\"threadID\"").count - 1 == 3)
    }

    @Test func fetchToolFoldersArgumentCanFetchJunk() async throws {
        let container = try EmailRepositoryTests.inMemoryContainer()
        let repository = EmailRepository(modelContext: ModelContext(container))
        repository.upsertMessages(
            [EmailRepositoryTests.simpleMessage(uid: 1, messageID: "<tool-junk@example.com>", subject: "Tool junk")],
            mailbox: "Spam",
            accountID: Self.accountID,
            role: .junk
        )
        repository.resolveThreads()

        let tool = EmailReviewFetchTool(
            modelContainer: container,
            applySuppression: false,
            defaults: Self.fetchDefaults(limit: 10)
        )
        let omitted = try await tool.execute(arguments: [:])
        #expect(!omitted.contains("Tool junk"))

        let requested = try await tool.execute(arguments: ["folders": .array([.string("Spam")])])
        #expect(requested.contains("Tool junk"))
    }

    private static func fetchDefaults(limit: Int) -> EmailReviewFetchDefaults {
        EmailReviewFetchDefaults(
            maxAgeDays: nil,
            limit: limit,
            includeFlagged: true,
            includeNotated: true,
            includeRead: true,
            includeUnread: true,
            includeArchived: false,
            includeTrashed: false
        )
    }
}
