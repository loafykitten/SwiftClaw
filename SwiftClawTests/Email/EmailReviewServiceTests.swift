import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Phase 14 follow-up (C1 + C2) regression tests for `EmailReviewService`.
///
/// C1: a failed inference pass must NOT stamp `lastReviewedAt` on the threads
/// it was supposed to triage — otherwise a single transient failure
/// (network blip, rate limit, context overflow) permanently suppresses them
/// from review until new mail lands. Stamping is only legitimate on success
/// (the H3 "nothing-to-do" case). The service exposes `completeProvider` as
/// an injectable test seam so these can run without the network.
///
/// C2: the service caps the batch handed to the LLM at
/// `SettingsStorage.defaultEmailReviewMaxThreads` so a fresh install with hundreds
/// of unreviewed threads doesn't blow up the context window — and pairs with
/// C1's stamp-only-what-was-sent so older unreviewed threads roll into the
/// next pass instead of being suppressed without ever being seen.
@MainActor
@Suite(.serialized)
struct EmailReviewServiceTests {
    @Test
    func failingInferencePassDoesNotSuppressThreads() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        // Seed a thread the review pass will try to triage.
        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<c1@example.com>", subject: "Triage me"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        // Confirm the thread is eligible for review before the pass.
        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        // Inject a failing inference path — simulates a network blip, auth
        // error, rate limit, or context-overflow throw.
        service.completeProvider = { _, _, _, _ in
            throw ToolError.executionFailed("simulated inference failure")
        }

        let didSucceed = await service.runOnce()
        #expect(didSucceed == false)
        #expect(service.lastStatusMessage == "Review failed")

        // C1 contract: the thread the failed pass was supposed to triage
        // must NOT be suppressed — the next pass should still pick it up.
        let afterFailure = repository.fetchNonArchivedThreadsForReview()
        #expect(afterFailure.count == 1)
    }

    @Test
    func successfulNoActionPassStillSuppressesThreads() async throws {
        // The legitimate H3 case: a successful pass where the model decided
        // "nothing needs attention" still stamps — a "nothing-to-do" thread
        // isn't re-sent on the next interval until new mail lands. This is
        // what the stamp-after-success contract preserves when C1 fixed the
        // failure path.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<c1-success@example.com>", subject: "Nothing to do"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        // A successful pass where the model fetched the inbox (so the threads
        // are recorded for stamping) but surfaced nothing — the legitimate
        // "looked, nothing to do" case.
        service.completeProvider = Self.fetchingProvider()

        let didSucceed = await service.runOnce()
        #expect(didSucceed == true)

        // Suppression applied — next pass skips this thread.
        #expect(repository.fetchNonArchivedThreadsForReview().isEmpty)
    }

    @Test
    func manualForceRetriagesAlreadyTriagedThreads() async throws {
        // The manual "Review Now" button passes `force: true` so a user can
        // re-triage an inbox where every thread was already reviewed in a
        // prior pass (the H3 suppression filter would otherwise short-circuit
        // with "all N inbox threads already triaged since last new mail;
        // skipping"). The scheduled loop keeps `force: false` so the H3
        // contract holds on the automatic cadence.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<force@example.com>", subject: "Already triaged"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        // First pass fetches (recording the thread) + stamps, so the
        // default-arg path now skips it.
        service.completeProvider = Self.fetchingProvider()

        _ = await service.runOnce()
        #expect(repository.fetchNonArchivedThreadsForReview().isEmpty)

        // Default-arg (scheduled-path) call short-circuits at the empty
        // fetch — no inference call, returns false.
        let capture = InferenceCallCapture()
        service.completeProvider = { _, _, _, _ in
            await capture.record()
            return ""
        }
        let scheduledDidRun = await service.runOnce()
        #expect(scheduledDidRun == false)
        #expect(service.lastStatusMessage == "Review is already up to date")
        let scheduledCalls = await capture.count
        #expect(scheduledCalls == 0)

        // Forced (manual-path) call ignores the suppression filter and
        // re-triages the already-stamped thread.
        let manualDidRun = await service.runOnce(force: true)
        #expect(manualDidRun == true)
        let manualCalls = await capture.count
        #expect(manualCalls == 1)
    }

    @Test
    func scheduledPassSkipsWhenPreviousReviewChatIsUnread() async throws {
        // If the user hasn't opened the last review chat yet, the scheduled
        // loop must not pile a fresh review on top — skip (without stamping,
        // and without an inference call) until the existing review is read.
        // The manual/conversational path (`force: true`) still runs.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<unread-guard@example.com>", subject: "New mail"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        // An unread review chat left over from a prior pass.
        let reviewChat = Chat(
            title: "\(Chat.emailReviewTitlePrefix) earlier today",
            modelSelection: "test-claw-model"
        )
        context.insert(reviewChat)
        try context.save()
        let reviewChatID = reviewChat.id

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        service.unreadChatIDsProvider = { [reviewChatID] }
        let capture = InferenceCallCapture()
        service.completeProvider = { _, _, _, _ in
            await capture.record()
            return ""
        }

        // Scheduled pass: the guard fires before inference or stamping.
        let scheduledDidRun = await service.runOnce()
        #expect(scheduledDidRun == false)
        #expect(service.lastStatusMessage == "Previous review is still unread")
        let scheduledCalls = await capture.count
        #expect(scheduledCalls == 0)
        // The new thread stays eligible for the pass that runs after the
        // user reads the review.
        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)

        // Forced pass ignores the guard.
        let forcedDidRun = await service.runOnce(force: true)
        #expect(forcedDidRun == true)
        let forcedCalls = await capture.count
        #expect(forcedCalls == 1)
    }

    @Test
    func scheduledPassRunsWhenUnreadChatIsNotAReview() async throws {
        // Only unread REVIEW chats gate the scheduler — an unread ordinary
        // conversation must not suppress inbox reviews.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<unread-other@example.com>", subject: "New mail"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        let ordinaryChat = Chat(title: "Weekend plans", modelSelection: "test-claw-model")
        context.insert(ordinaryChat)
        try context.save()
        let ordinaryChatID = ordinaryChat.id

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        service.unreadChatIDsProvider = { [ordinaryChatID] }
        service.completeProvider = Self.fetchingProvider()

        let didRun = await service.runOnce()
        #expect(didRun == true)
    }

    @Test
    func reviewBatchCapsAtMaxThreadsPerPass() async throws {
        // C2 regression (now enforced by the `fetch_inbox_emails` default
        // limit): seed more unreviewed READ threads than the per-pass cap. The
        // fetch tool must return + the service stamp only `maxThreadsPerPass`
        // of them; the remainder stays eligible for the next pass. (Read, not
        // unread — unread intentionally overrides the cap.)
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let total = SettingsStorage.defaultEmailReviewMaxThreads + 5
        let accountID = UUID()
        for index in 1...total {
            // Distinct past dates so the cap picks a deterministic newest
            // subset, and a stamp at `Date.now` is strictly newer than every
            // seeded date.
            let date = Date().addingTimeInterval(TimeInterval(-index))
            let message = Self.message(
                uid: index,
                messageID: "<c2-\(index)@example.com>",
                subject: "Thread \(index)",
                date: date,
                isRead: true
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: accountID)
            repository.resolveThreads()
        }

        // Sanity: all threads are eligible before the pass.
        #expect(repository.fetchNonArchivedThreadsForReview().count == total)

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        let capture = FetchResultCapture()
        service.completeProvider = Self.fetchingProvider(capture: capture)

        _ = await service.runOnce()

        // The fetch tool's JSON result must encode exactly `maxThreadsPerPass`
        // thread descriptors (the encoder uses `[.prettyPrinted, .sortedKeys]`,
        // so each descriptor contributes one `"threadID"` occurrence).
        let result = try #require(await capture.result)
        let descriptorCount = result.components(separatedBy: "\"threadID\"").count - 1
        #expect(descriptorCount == SettingsStorage.defaultEmailReviewMaxThreads)

        // The threads that weren't fetched must stay eligible for the next pass
        // — stamp-only-what-was-fetched means unfetched threads aren't
        // suppressed. They roll forward to the next interval.
        let stillEligible = repository.fetchNonArchivedThreadsForReview()
        #expect(stillEligible.count == total - SettingsStorage.defaultEmailReviewMaxThreads)
    }

    @Test
    func fetchNonArchivedThreadsForReviewRespectsLimit() async throws {
        // Repository-level contract: `limit` caps the returned count of plain
        // (read) threads. Unread threads override the cap, so this uses read
        // mail to exercise the limit itself.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let accountID = UUID()
        for index in 1...10 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index,
                messageID: "<lim-\(index)@example.com>",
                subject: "Capped \(index)",
                isRead: true,
                date: Date().addingTimeInterval(TimeInterval(-index))
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: accountID)
            repository.resolveThreads()
        }

        // Without a limit: all 10 threads return.
        #expect(repository.fetchNonArchivedThreadsForReview().count == 10)

        // With a limit: at most `limit` threads return.
        #expect(repository.fetchNonArchivedThreadsForReview(limit: 3).count == 3)
        #expect(repository.fetchNonArchivedThreadsForReview(limit: 7).count == 7)
    }

    @Test
    func reviewPromptOmitsArchivedMessagesFromMixedThread() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountID = UUID()
        let active = Self.message(
            uid: 1,
            messageID: "<active-mixed@example.com>",
            subject: "Shared thread",
            date: Date().addingTimeInterval(-120),
            fromAddress: "active@example.com",
            bodyText: "Active body still needs attention"
        )
        let archived = Self.message(
            uid: 2,
            messageID: "<archived-mixed@example.com>",
            subject: "Shared thread",
            date: Date().addingTimeInterval(-60),
            fromAddress: "archived@example.com",
            bodyText: "Archived body should stay out"
        )

        repository.upsertMessages([active, archived], mailbox: "INBOX", accountID: accountID)
        repository.resolveThreads()

        let archivedEmail = try #require(
            try context.fetch(FetchDescriptor<Email>()).first { $0.uid == 2 }
        )
        repository.archive(messageID: archivedEmail.id)

        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        let capture = FetchResultCapture()
        service.completeProvider = Self.fetchingProvider(capture: capture)

        let didRun = await service.runOnce()
        #expect(didRun == true)

        // The fetched thread JSON describes only the active message; the
        // archived one is omitted (`EmailReviewThreadDescriptor.make` uses the
        // reviewable set).
        let result = try #require(await capture.result)
        #expect(result.contains("active@example.com"))
        #expect(result.contains("Active body still needs attention"))
        #expect(!result.contains("archived@example.com"))
        #expect(!result.contains("Archived body should stay out"))
    }

    @Test
    func reviewSystemPromptCarriesConfiguredPersona() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let accountID = UUID()
        let message = Self.message(
            uid: 1,
            messageID: "<persona@example.com>",
            subject: "Needs attention",
            date: .now
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: accountID)
        repository.resolveThreads()

        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("test-claw-model", forKey: SettingsKeys.clawModel)
        fixture.defaults.set("Mittens", forKey: SettingsKeys.assistantDisplayName)
        fixture.defaults.set(true, forKey: SettingsKeys.assistantUsesCustomPersonality)
        fixture.defaults.set("Speak like a terse pirate captain.", forKey: SettingsKeys.assistantCustomPersonality)

        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        let capture = PromptCapture()
        service.completeProvider = { messages, _, _, _ in
            await capture.record(messages: messages)
            return ""
        }

        #expect(await service.runOnce() == true)

        let systemPrompt = try #require(await capture.systemPrompt)
        #expect(systemPrompt.contains("Mittens"))
        #expect(systemPrompt.contains("Speak like a terse pirate captain."))
        #expect(systemPrompt.contains("Current user date/time:"))
        // The triage instructions still ride alongside the persona.
        #expect(systemPrompt.contains("notify_user_about_emails"))
        // The cold (scheduled) path has no user turn to steer it.
        #expect(!systemPrompt.contains("steer this run"))
    }

    @Test
    func reanalysisReplaysChatHistoryAndAsksForContinuation() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)
        let message = Self.message(
            uid: 1,
            messageID: "<reanalyze@example.com>",
            subject: "Needs another look",
            date: .now
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        // An existing review chat with a prior exchange + an (empty) card.
        let chat = Chat(title: "Inbox review", modelSelection: "test-claw-model")
        let priorSummary = ChatMessage(
            role: .assistant, content: "Earlier I flagged the budget thread.", sortIndex: 0
        )
        let priorCard = ChatMessage(
            role: .assistant, content: "", sortIndex: 1,
            reviewCard: ReviewCardPayload(reviewType: .email, items: [])
        )
        let userAsk = ChatMessage(
            role: .user, content: "Could you run an additional analysis?", sortIndex: 2
        )
        context.insert(chat)
        [priorSummary, priorCard, userAsk].forEach {
            $0.chat = chat
            context.insert($0)
        }
        try context.save()

        let fixture = try Self.fixtureWithClawModel()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        let capture = PromptCapture()
        service.completeProvider = { messages, _, _, _ in
            await capture.record(messages: messages)
            return ""
        }

        #expect(await service.runOnce(force: true, targetChatID: chat.id) == true)

        let contents = await capture.allMessages.compactMap { message -> String? in
            switch message {
            case .user(let content, _): return content
            case .assistant(let content): return content
            case .system(let content): return content
            }
        }
        // Prior conversation is replayed; the empty card message (and any
        // other whitespace-only content) is filtered out by `chatHistory`.
        #expect(contents.contains("Earlier I flagged the budget thread."))
        #expect(contents.contains("Could you run an additional analysis?"))
        #expect(contents.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        // The system prompt asks the model to continue rather than restart, and
        // to honor any steering in the user's latest message for this run.
        let systemPrompt = try #require(await capture.systemPrompt)
        #expect(systemPrompt.contains("natural continuation"))
        #expect(systemPrompt.contains("steer this run"))
    }

    @Test
    func runOnceSkipsWhenModelNotConfiguredWithoutStamping() async throws {
        // The model-not-configured guard must also short-circuit BEFORE
        // stamping — otherwise disabling the model after seeding threads
        // would brick the reviewer until the user picks a model + new mail
        // arrives. (Part of the C1 guard-reorder.)
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let message = EmailRepositoryTests.simpleMessage(
            uid: 1, messageID: "<c1-nomodel@example.com>", subject: "Pick a model"
        )
        repository.upsertMessages([message], mailbox: "INBOX", accountID: UUID())
        repository.resolveThreads()

        // Isolated defaults with NO clawModel set.
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let service = EmailReviewService(modelContainer: container, userDefaults: fixture.defaults)
        service.completeProvider = { _, _, _, _ in
            Issue.record("inference must not be called when no model is configured")
            return ""
        }

        let didSucceed = await service.runOnce()
        #expect(didSucceed == false)
        #expect(service.lastStatusMessage == "Review needs a model in Settings")

        // The thread must still be eligible — no stamp.
        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)
    }

    // MARK: - Helpers

    /// Builds an isolated `UserDefaults` fixture pre-seeded with a `clawModel`
    /// value so the model-configured guard in `EmailReviewService.runOnce`
    /// doesn't short-circuit. Caller owns the cleanup (`fixture.cleanup()`).
    private static func fixtureWithClawModel() throws -> UserDefaultsFixture {
        let fixture = try UserDefaultsFixture()
        fixture.defaults.set("test-claw-model", forKey: SettingsKeys.clawModel)
        return fixture
    }

    private actor PromptCapture {
        private(set) var userPrompt: String? = nil
        private(set) var systemPrompt: String? = nil
        private(set) var allMessages: [InferenceMessage] = []

        func record(messages: [InferenceMessage]) {
            allMessages = messages
            for message in messages {
                switch message {
                case .user(let content, _):
                    userPrompt = content
                case .system(let content):
                    systemPrompt = content
                case .assistant:
                    break
                }
            }
        }
    }

    private actor InferenceCallCapture {
        private(set) var count: Int = 0

        func record() {
            count += 1
        }
    }

    private actor FetchResultCapture {
        private(set) var result: String?

        func record(_ value: String) {
            result = value
        }
    }

    /// Builds a `completeProvider` that simulates the agentic loop's first
    /// round: the model calls `fetch_inbox_emails` (with `arguments`) before
    /// replying. The real `InferenceService` executes tool calls itself, but
    /// the injected seam replaces it, so a test that needs the fetch tool's
    /// side effects (thread-ID collection → stamping) must drive it here.
    /// Optionally records the tool's JSON result for assertions.
    private static func fetchingProvider(
        arguments: [String: JSONValue] = [:],
        capture: FetchResultCapture? = nil
    ) -> EmailReviewInferenceComplete {
        { _, _, _, tools in
            if let fetchTool = tools.first(where: { $0.name == "fetch_inbox_emails" }) {
                let result = (try? await fetchTool.execute(arguments: arguments)) ?? ""
                await capture?.record(result)
            }
            return ""
        }
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    static func message(
        uid: Int,
        messageID: String,
        subject: String,
        date: Date,
        fromAddress: String = "sender@example.com",
        bodyText: String = "Body",
        isRead: Bool = false
    ) -> FetchedMessage {
        FetchedMessage(
            uid: uid,
            messageID: messageID,
            subject: subject,
            fromAddress: fromAddress,
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: date,
            internalDate: date,
            bodyText: bodyText,
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: isRead,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
    }
}
