import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct NotesWorkflowManagerTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([Chat.self, ChatMessage.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func disabledWorkflowDoesNotStart() async throws {
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        let manager = NotesWorkflowManager.shared; manager.resetForTesting(); defer { manager.resetForTesting() }
        fixture.defaults.set(false, forKey: SettingsKeys.notesEnabled)
        let probe = NotesWorkflowProbe()
        manager.configureForTesting(userDefaults: fixture.defaults) { _, _, _ in await probe.record(); return true }
        try manager.start(modelContainer: container())
        #expect(await manager.reviewNow() == nil)
        #expect(await probe.count == 0)
    }

    @Test func overdueScheduleRunsAndSuccessfulPassIsStamped() async throws {
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        let manager = NotesWorkflowManager.shared; manager.resetForTesting(); defer { manager.resetForTesting() }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)
        fixture.defaults.set(60, forKey: SettingsKeys.notesReviewIntervalSeconds)
        SettingsStorage.saveNotesLastReviewCompletedAt(.now.addingTimeInterval(-120), userDefaults: fixture.defaults)
        let probe = NotesWorkflowProbe()
        manager.configureForTesting(userDefaults: fixture.defaults) { _, force, target in
            await probe.record(force: force, target: target)
            SettingsStorage.saveNotesLastReviewCompletedAt(.now, userDefaults: fixture.defaults)
            return true
        }
        try manager.start(modelContainer: container())
        try await waitForCount(probe, 1)
        #expect(await probe.runs.first?.force == false)
        #expect(SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: fixture.defaults) != nil)
    }

    @Test func reviewNowForwardsTargetAndMutualExclusionAllowsOnePass() async throws {
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        let manager = NotesWorkflowManager.shared; manager.resetForTesting(); defer { manager.resetForTesting() }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled); fixture.defaults.set(0, forKey: SettingsKeys.notesReviewIntervalSeconds)
        let probe = NotesWorkflowProbe(); let target = UUID()
        manager.configureForTesting(userDefaults: fixture.defaults) { _, force, target in
            await probe.record(force: force, target: target); try? await Task.sleep(for: .milliseconds(150)); return true
        }
        try manager.start(modelContainer: container())
        async let first = manager.reviewNow(appendingTo: target)
        async let second = manager.reviewNow()
        let statuses = await [first, second]
        #expect(await probe.count == 1); #expect(statuses.contains("Review already in progress"))
        let run = await probe.runs.first
        #expect(run?.force == true)
        #expect(run?.target == target || run?.target == nil)
    }

    @Test func stopEndsLifecycleAndReviewNowNoOps() async throws {
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        let manager = NotesWorkflowManager.shared; manager.resetForTesting(); defer { manager.resetForTesting() }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled); fixture.defaults.set(0, forKey: SettingsKeys.notesReviewIntervalSeconds)
        manager.configureForTesting(userDefaults: fixture.defaults) { _, _, _ in true }
        try manager.start(modelContainer: container()); manager.stop()
        #expect(await manager.reviewNow() == nil)
    }

    private func waitForCount(_ probe: NotesWorkflowProbe, _ count: Int) async throws {
        let deadline = Date.now.addingTimeInterval(1)
        while Date.now < deadline {
            if await probe.count >= count {
                return
            }; try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for scheduled Notes review")
    }
}

private actor NotesWorkflowProbe {
    struct Run: Sendable { let force: Bool; let target: UUID? }
    private(set) var runs: [Run] = []
    func record(force: Bool = false, target: UUID? = nil) {
        runs.append(.init(force: force, target: target))
    }

    var count: Int {
        runs.count
    }
}
