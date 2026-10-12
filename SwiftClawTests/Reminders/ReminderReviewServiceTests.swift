import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct ReminderReviewServiceTests {
    private struct Harness {
        let container: ModelContainer
        let repository: ReminderRepository
        let service: ReminderReviewService
        let fixture: UserDefaultsFixture

        @MainActor
        init() throws {
            let schema = Schema([Reminder.self, ReminderList.self, Chat.self, ChatMessage.self])
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            repository = ReminderRepository(modelContext: ModelContext(container))
            fixture = try UserDefaultsFixture()
            fixture.defaults.set("test-model", forKey: SettingsKeys.clawModel)
            service = ReminderReviewService(modelContainer: container, userDefaults: fixture.defaults)
            service.unreadChatIDsProvider = { [] }
        }

        @MainActor
        @discardableResult
        func insertPendingReminder(
            title: String = "Pending",
            dueDate: Date? = .now.addingTimeInterval(24 * 3600)
        ) -> Reminder {
            repository.insert(
                Reminder(title: title, dueDate: dueDate, hasDueTime: dueDate != nil),
                into: repository.defaultList()
            )
        }

        func cleanup() {
            fixture.cleanup()
        }
    }

    @Test func skipsWithoutModelConfigured() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.fixture.defaults.removeObject(forKey: SettingsKeys.clawModel)
        harness.insertPendingReminder()

        let didRun = await harness.service.runOnce(force: true)
        #expect(!didRun)
        #expect(harness.service.lastStatusMessage == "Review needs a model in Settings")
    }

    @Test func skipsScheduledPassWhenNothingPending() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let inferenceCalls = LockedValue(0)
        harness.service.completeProvider = { _, _, _, _ in
            inferenceCalls.update { $0 += 1 }
            return ""
        }

        // A completed reminder and one due far beyond the guard horizon are
        // both out of scope for a scheduled pass.
        let done = harness.insertPendingReminder(title: "Done")
        harness.repository.complete(done)
        harness.insertPendingReminder(title: "Far", dueDate: .now.addingTimeInterval(30 * 24 * 3600))

        let didRun = await harness.service.runOnce(force: false)
        #expect(!didRun)
        #expect(inferenceCalls.value == 0)
        #expect(harness.service.lastStatusMessage == "No pending reminders to review")
    }

    @Test func skipsScheduledPassWhileReviewChatUnread() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.insertPendingReminder()

        // An unread reminders-review chat exists.
        let context = harness.container.mainContext
        let chat = Chat(title: "\(Chat.remindersReviewTitlePrefix) Jul 10", modelSelection: "test-model")
        context.insert(chat)
        try context.save()
        harness.service.unreadChatIDsProvider = { [chat.id] }

        let didRun = await harness.service.runOnce(force: false)
        #expect(!didRun)
        #expect(harness.service.lastStatusMessage == "Previous review is still unread")

        // Forced (manual) passes still run.
        harness.service.completeProvider = { _, _, _, _ in "" }
        let forced = await harness.service.runOnce(force: true)
        #expect(forced)
    }

    @Test func skipsScheduledPassWhenNothingChangedSinceLastReview() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let reminder = harness.insertPendingReminder()

        // Everything pending already reviewed, nothing modified since →
        // a scheduled pass would just re-send the same to-dos.
        reminder.lastReviewedAt = .now
        harness.repository.saveChanges()

        let inferenceCalls = LockedValue(0)
        harness.service.completeProvider = { _, _, _, _ in
            inferenceCalls.update { $0 += 1 }
            return ""
        }
        let didRun = await harness.service.runOnce(force: false)
        #expect(!didRun)
        #expect(inferenceCalls.value == 0)
        #expect(harness.service.lastStatusMessage == "Nothing new since the last review")

        // Editing the reminder (modifiedAt bump) makes the next scheduled
        // pass eligible again; forced passes were never suppressed.
        harness.repository.noteUpdated(reminder)
        let didRunAfterEdit = await harness.service.runOnce(force: false)
        #expect(didRunAfterEdit)
        #expect(inferenceCalls.value == 1)
    }

    @Test func stampsFetchedRemindersOnlyAfterSuccess() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let reminder = harness.insertPendingReminder()

        // The model "fetches" via the tool, then the call fails: no stamp.
        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_reminders" }) {
                _ = try await fetch.execute(arguments: [:])
            }
            throw ToolError.executionFailed("simulated network failure")
        }
        // Assertions read through a FRESH context: the service stamps in its
        // own `ModelContext`, so the harness's cached instance would be stale.
        func freshStamp() -> Date? {
            ReminderRepository(modelContext: ModelContext(harness.container))
                .reminder(withID: reminder.id)?.lastReviewedAt
        }

        let failed = await harness.service.runOnce(force: true)
        #expect(!failed)
        #expect(freshStamp() == nil)

        // Success: the fetched reminder is stamped.
        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_reminders" }) {
                _ = try await fetch.execute(arguments: [:])
            }
            return "reviewed, nothing to surface"
        }
        let succeeded = await harness.service.runOnce(force: true)
        #expect(succeeded)
        #expect(freshStamp() != nil)
    }

    @Test func scopedRegistryOffersExactlyTheReviewTools() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.insertPendingReminder()

        let offeredTools = LockedValue<[String]>([])
        harness.service.completeProvider = { _, _, _, tools in
            offeredTools.update { $0 = tools.map(\.name).sorted() }
            return ""
        }
        _ = await harness.service.runOnce(force: true)
        #expect(offeredTools.value == ["fetch_reminders", "notify_user_about_reminders"])
    }

    // MARK: - Fetch tool scope

    @Test func fetchIncludesOverdueAndUndatedAndExcludesCompletedAndFarFuture() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.insertPendingReminder(title: "Overdue", dueDate: .now.addingTimeInterval(-3 * 24 * 3600))
        harness.insertPendingReminder(title: "Soon", dueDate: .now.addingTimeInterval(24 * 3600))
        harness.insertPendingReminder(title: "Inbox", dueDate: nil)
        harness.insertPendingReminder(title: "Far", dueDate: .now.addingTimeInterval(30 * 24 * 3600))
        let done = harness.insertPendingReminder(title: "Done", dueDate: .now.addingTimeInterval(3600))
        harness.repository.complete(done)

        let tool = ReminderReviewFetchTool(modelContainer: harness.container)
        let output = try await tool.execute(arguments: [:])
        #expect(output.contains("Overdue"))
        #expect(output.contains("overdue: yes"))
        #expect(output.contains("Soon"))
        #expect(output.contains("Inbox"))
        #expect(output.contains("no due date"))
        #expect(!output.contains("Far"))
        #expect(!output.contains("Done"))

        // Overdue-and-due items come before undated ones.
        let overdueRange = try #require(output.range(of: "Overdue"))
        let inboxRange = try #require(output.range(of: "Inbox"))
        #expect(overdueRange.lowerBound < inboxRange.lowerBound)
    }

    @Test func fetchCanExcludeUndatedReminders() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.insertPendingReminder(title: "Soon", dueDate: .now.addingTimeInterval(3600))
        harness.insertPendingReminder(title: "Inbox", dueDate: nil)

        let tool = ReminderReviewFetchTool(modelContainer: harness.container)
        let output = try await tool.execute(arguments: ["include_undated": .bool(false)])
        #expect(output.contains("Soon"))
        #expect(!output.contains("Inbox"))
    }

    @Test func dateOnlyReminderIsNotOverdueUntilItsDayPasses() throws {
        let calendar = Calendar.current
        let today = Reminder(title: "Today", dueDate: calendar.startOfDay(for: .now), hasDueTime: false)
        #expect(!ReminderReviewFetchTool.isOverdue(today, now: .now))

        let yesterday = Reminder(
            title: "Yesterday",
            dueDate: calendar.startOfDay(for: .now.addingTimeInterval(-24 * 3600)),
            hasDueTime: false
        )
        #expect(ReminderReviewFetchTool.isOverdue(yesterday, now: .now))
    }

    // MARK: - Stamp versions and scope

    /// An edit that lands after the model fetched (but before the pass
    /// finished) was never reviewed: it must not be stamped, or the next
    /// scheduled pass would skip it. Unchanged rows are still stamped.
    @Test func editDuringThePassIsNotStampedAsReviewed() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let edited = harness.insertPendingReminder(title: "Edited mid-pass")
        let untouched = harness.insertPendingReminder(title: "Untouched")
        let editedID = edited.id
        let container = harness.container

        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_reminders" }) {
                _ = try await fetch.execute(arguments: [:])
            }
            await MainActor.run {
                let repository = ReminderRepository(modelContext: ModelContext(container))
                if let reminder = repository.reminder(withID: editedID) {
                    reminder.title = "Edited after the fetch"
                    repository.noteUpdated(reminder)
                }
            }
            return ""
        }
        #expect(await harness.service.runOnce(force: true))

        let fresh = ReminderRepository(modelContext: ModelContext(harness.container))
        #expect(fresh.reminder(withID: edited.id)?.lastReviewedAt == nil)
        #expect(fresh.reminder(withID: untouched.id)?.lastReviewedAt != nil)
    }

    /// The "anything changed?" guard spans the whole scope, and the fetch
    /// admits changed rows first: a change to the 60th pending reminder
    /// both triggers a pass and reaches the model.
    @Test func changeBeyondTheFirstPageTriggersAPassAndIsFetched() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        var reminders: [Reminder] = []
        for index in 0..<60 {
            reminders.append(harness.insertPendingReminder(
                title: "Chore \(index)",
                dueDate: .now.addingTimeInterval(TimeInterval(index + 1) * 600)
            ))
        }
        let reviewedAt = Date.now
        for reminder in reminders {
            reminder.lastReviewedAt = reviewedAt
        }
        harness.repository.saveChanges()
        let last = try #require(reminders.last)
        last.title = "Chore 59 (changed)"
        harness.repository.noteUpdated(last)

        let fetchedOutput = LockedValue("")
        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_reminders" }) {
                let output = try await fetch.execute(arguments: [:])
                fetchedOutput.update { $0 = output }
            }
            return ""
        }
        #expect(await harness.service.runOnce(force: false))
        #expect(fetchedOutput.value.contains(last.id.uuidString))
        #expect(fetchedOutput.value.hasPrefix("50 of 60 reminders"))
    }
}
