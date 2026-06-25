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
/// `EmailReviewService.maxThreadsPerPass` so a fresh install with hundreds
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

        UserDefaults.standard.set("test-claw-model", forKey: SettingsKeys.clawModel)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.clawModel) }

        let service = EmailReviewService(modelContainer: container)
        // Inject a failing inference path — simulates a network blip, auth
        // error, rate limit, or context-overflow throw.
        service.completeProvider = { _, _, _, _ in
            throw ToolError.executionFailed("simulated inference failure")
        }

        let didSucceed = await service.runOnce()
        #expect(didSucceed == false)

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

        UserDefaults.standard.set("test-claw-model", forKey: SettingsKeys.clawModel)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.clawModel) }

        let service = EmailReviewService(modelContainer: container)
        // A successful pass that produces no tool call (the model decided
        // nothing needed attention). Returns an empty assistant reply.
        service.completeProvider = { _, _, _, _ in "" }

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

        UserDefaults.standard.set("test-claw-model", forKey: SettingsKeys.clawModel)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.clawModel) }

        let service = EmailReviewService(modelContainer: container)
        service.completeProvider = { _, _, _, _ in "" }

        // First pass: succeeds + stamps, so the default-arg path now skips.
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
    func reviewBatchCapsAtMaxThreadsPerPass() async throws {
        // C2 regression: seed more unreviewed threads than the per-pass cap.
        // The service must only send + stamp `maxThreadsPerPass` of them;
        // the remainder stays eligible for the next pass.
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let total = EmailReviewService.maxThreadsPerPass + 5
        let accountID = UUID()
        for index in 1...total {
            // Distinct PAST dates so the cap (which takes the N most-recent
            // threads) picks a deterministic subset, AND so a stamp at
            // `Date.now` (after seeding) is strictly newer than every
            // seeded `latestMessage.date` — otherwise the suppression filter
            // (`lastReviewedAt < latestMessageDate`) would still consider a
            // stamped thread eligible.
            let date = Date().addingTimeInterval(TimeInterval(-index))
            let message = Self.message(
                uid: index,
                messageID: "<c2-\(index)@example.com>",
                subject: "Thread \(index)",
                date: date
            )
            repository.upsertMessages([message], mailbox: "INBOX", accountID: accountID)
            repository.resolveThreads()
        }

        // Sanity: all threads are eligible before the pass.
        #expect(repository.fetchNonArchivedThreadsForReview().count == total)

        UserDefaults.standard.set("test-claw-model", forKey: SettingsKeys.clawModel)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.clawModel) }

        let service = EmailReviewService(modelContainer: container)
        let capture = PromptCapture()
        service.completeProvider = { messages, _, _, _ in
            await capture.record(messages: messages)
            return ""
        }

        _ = await service.runOnce()

        // C2: the user prompt the LLM received must encode exactly
        // `maxThreadsPerPass` thread descriptors (the JSON encoder uses
        // `[.prettyPrinted, .sortedKeys]`, so each descriptor contributes one
        // `"threadID":` occurrence).
        let prompt = await capture.userPrompt
        let nonNilPrompt = try #require(prompt)
        // Encoder uses `[.prettyPrinted, .sortedKeys]`; either `"threadID":`
        // or `"threadID" :` depending on encoder spacing. Match the quoted
        // key up to the colon to be spacing-agnostic.
        let descriptorCount = nonNilPrompt.components(separatedBy: "\"threadID\"").count - 1
        #expect(descriptorCount == EmailReviewService.maxThreadsPerPass)

        // The threads that weren't sent must stay eligible for the next pass
        // — C1's stamp-only-what-was-sent means unsent threads aren't
        // suppressed. They roll forward to the next interval. Use the
        // seeding `repository` so the post-check sees the stamps (the
        // auto-merge from sibling-context saves lands in the seeding
        // context's graph, mirroring `successfulNoActionPassStillSuppressesThreads`).
        let stillEligible = repository.fetchNonArchivedThreadsForReview()
        #expect(stillEligible.count == total - EmailReviewService.maxThreadsPerPass)
    }

    @Test
    func fetchNonArchivedThreadsForReviewRespectsLimit() async throws {
        // Repository-level contract for C2: `limit` caps the returned count.
        // (Used by the service to cap the batch handed to the LLM.)
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let accountID = UUID()
        for index in 1...10 {
            let message = EmailRepositoryTests.simpleMessage(
                uid: index,
                messageID: "<lim-\(index)@example.com>",
                subject: "Capped \(index)"
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

        UserDefaults.standard.removeObject(forKey: SettingsKeys.clawModel)
        let service = EmailReviewService(modelContainer: container)
        service.completeProvider = { _, _, _, _ in
            Issue.record("inference must not be called when no model is configured")
            return ""
        }

        let didSucceed = await service.runOnce()
        #expect(didSucceed == false)

        // The thread must still be eligible — no stamp.
        #expect(repository.fetchNonArchivedThreadsForReview().count == 1)
    }

    // MARK: - Helpers

    private actor PromptCapture {
        private(set) var userPrompt: String? = nil

        func record(messages: [InferenceMessage]) {
            for message in messages {
                if case .user(let content, _) = message {
                    userPrompt = content
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
        date: Date
    ) -> FetchedMessage {
        FetchedMessage(
            uid: uid,
            messageID: messageID,
            subject: subject,
            fromAddress: "sender@example.com",
            toAddresses: ["me@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: date,
            internalDate: date,
            bodyText: "Body",
            bodyHTML: nil,
            inReplyTo: nil,
            references: [],
            isRead: false,
            isFlagged: false,
            mailbox: "INBOX",
            attachmentDescriptors: []
        )
    }
}
