import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
@Suite(.serialized)
struct EmailWorkflowManagerTests {
    @Test
    func accountAddedRefreshRunsInjectedHandler() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let manager = EmailWorkflowManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }

        let probe = AccountAddedRefreshProbe()
        manager.configureForTesting(
            userDefaults: fixture.defaults,
            accountAddedRefreshHandler: {
                await probe.record()
            }
        )

        manager.refreshAfterAccountAdded()

        #expect(try await Self.waitForRefresh(in: probe) == 1)
    }

    @Test
    func overdueIntervalReviewRunsWhenWorkflowStarts() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let manager = EmailWorkflowManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }

        let interval = SettingsStorage.defaultEmailReviewIntervalSeconds
        let staleCompletedAt = Date().addingTimeInterval(-TimeInterval(interval + 30))
        fixture.defaults.set(true, forKey: SettingsKeys.emailEnabled)
        fixture.defaults.set(interval, forKey: SettingsKeys.emailReviewIntervalSeconds)
        fixture.defaults.set(EmailReviewScheduleMode.interval.rawValue, forKey: SettingsKeys.emailReviewScheduleMode)
        SettingsStorage.saveEmailLastReviewCompletedAt(staleCompletedAt, userDefaults: fixture.defaults)

        let probe = ReviewRunProbe()
        manager.configureForTesting(
            userDefaults: fixture.defaults,
            schedulerFactory: { _, _ in [NoOpMailSyncScheduler()] },
            reviewRunHandler: { _, force, targetChatID, conversational in
                await probe.record(
                    force: force,
                    targetChatID: targetChatID,
                    conversational: conversational
                )
                return true
            }
        )

        let completionProbe = ReviewCompletionNotificationProbe()

        manager.start(modelContainer: try Self.inMemoryContainer())

        let run = try #require(await Self.waitForRun(in: probe))
        #expect(run.force == false)
        #expect(run.targetChatID == nil)
        #expect(run.conversational == false)

        let completedAt = try #require(
            SettingsStorage.loadEmailLastReviewCompletedAt(userDefaults: fixture.defaults)
        )
        #expect(completedAt > staleCompletedAt)
        #expect(try await Self.waitForCompletionNotification(in: completionProbe))
    }

    @Test
    func simultaneousReviewRequestsRunOnlyOnePass() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let manager = EmailWorkflowManager.shared
        manager.resetForTesting()
        defer { manager.resetForTesting() }

        fixture.defaults.set(true, forKey: SettingsKeys.emailEnabled)
        // A fresh completion stamp keeps the scheduled loop from also firing
        // during the test window — only the two manual calls compete.
        SettingsStorage.saveEmailLastReviewCompletedAt(Date(), userDefaults: fixture.defaults)

        let probe = ReviewRunProbe()
        manager.configureForTesting(
            userDefaults: fixture.defaults,
            schedulerFactory: { _, _ in [NoOpMailSyncScheduler()] },
            reviewRunHandler: { _, _, _, _ in
                // Slow pass: the second request arrives while this one is
                // mid-flight and must no-op instead of running a second pass.
                await probe.record(force: true, targetChatID: nil, conversational: false)
                try? await Task.sleep(for: .milliseconds(200))
                return true
            }
        )
        manager.start(modelContainer: try Self.inMemoryContainer())

        async let first = manager.reviewNow()
        async let second = manager.reviewNow()
        let statuses = await [first, second]

        #expect(await probe.runCount == 1)
        #expect(statuses.contains("Review already in progress"))
    }

    private static func waitForCompletionNotification(
        in probe: ReviewCompletionNotificationProbe,
        timeout: TimeInterval = 1
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe.didReceive { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return probe.didReceive
    }

    private static func waitForRun(
        in probe: ReviewRunProbe,
        timeout: TimeInterval = 1
    ) async throws -> ReviewRunProbe.RecordedRun? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let run = await probe.firstRun() {
                return run
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await probe.firstRun()
    }

    private static func waitForRefresh(
        in probe: AccountAddedRefreshProbe,
        timeout: TimeInterval = 1
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await probe.count
            if count > 0 {
                return count
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await probe.count
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Item.self, Chat.self, ChatMessage.self,
            Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}

/// Records whether `emailReviewCompletionDidChange` fired. Main-actor because
/// the workflow manager posts from the main actor.
@MainActor
private final class ReviewCompletionNotificationProbe {
    private(set) var didReceive = false
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: SettingsNotifications.emailReviewCompletionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didReceive = true
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private actor AccountAddedRefreshProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor ReviewRunProbe {
    struct RecordedRun: Sendable {
        let force: Bool
        let targetChatID: UUID?
        let conversational: Bool
    }

    private var runs: [RecordedRun] = []

    func record(force: Bool, targetChatID: UUID?, conversational: Bool) {
        runs.append(
            RecordedRun(
                force: force,
                targetChatID: targetChatID,
                conversational: conversational
            )
        )
    }

    func firstRun() -> RecordedRun? {
        runs.first
    }

    var runCount: Int {
        runs.count
    }
}

private final class NoOpMailSyncScheduler: MailSyncScheduler, @unchecked Sendable {
    let lastSyncDate: Date? = nil

    func start() {}

    func stop() {}

    func refreshNow() async {}
}
