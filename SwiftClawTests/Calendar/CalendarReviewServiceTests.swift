import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

@MainActor
struct CalendarReviewServiceTests {
    private struct Harness {
        let container: ModelContainer
        let repository: CalendarRepository
        let service: CalendarReviewService
        let fixture: UserDefaultsFixture

        @MainActor
        init() throws {
            let schema = Schema([CalendarEvent.self, UserCalendar.self, Chat.self, ChatMessage.self])
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            repository = CalendarRepository(modelContext: ModelContext(container))
            fixture = try UserDefaultsFixture()
            fixture.defaults.set("test-model", forKey: SettingsKeys.clawModel)
            service = CalendarReviewService(modelContainer: container, userDefaults: fixture.defaults)
            service.unreadChatIDsProvider = { [] }
        }

        @MainActor
        @discardableResult
        func insertUpcomingEvent(title: String = "Upcoming") -> CalendarEvent {
            repository.insert(CalendarEvent(
                title: title,
                startDate: .now.addingTimeInterval(24 * 3600),
                endDate: .now.addingTimeInterval(25 * 3600),
                calendar: repository.defaultCalendar()
            ))
        }

        func cleanup() {
            fixture.cleanup()
        }
    }

    @Test func skipsWithoutModelConfigured() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.fixture.defaults.removeObject(forKey: SettingsKeys.clawModel)
        harness.insertUpcomingEvent()

        let didRun = await harness.service.runOnce(force: true)
        #expect(!didRun)
        #expect(harness.service.lastStatusMessage == "Review needs a model in Settings")
    }

    @Test func skipsScheduledPassWhenNothingUpcoming() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let inferenceCalls = LockedValue(0)
        harness.service.completeProvider = { _, _, _, _ in
            inferenceCalls.update { $0 += 1 }
            return ""
        }

        let didRun = await harness.service.runOnce(force: false)
        #expect(!didRun)
        #expect(inferenceCalls.value == 0)
        #expect(harness.service.lastStatusMessage == "Nothing on the calendar to review")
    }

    @Test func skipsScheduledPassWhileReviewChatUnread() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.insertUpcomingEvent()

        // An unread calendar-review chat exists.
        let context = harness.container.mainContext
        let chat = Chat(title: "\(Chat.calendarReviewTitlePrefix) Jul 10", modelSelection: "test-model")
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
        let event = harness.insertUpcomingEvent()

        // Everything upcoming already reviewed, nothing modified since →
        // a scheduled pass would just re-send the same schedule.
        event.lastReviewedAt = .now
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

        // Editing the event (modifiedAt bump) makes the next scheduled pass
        // eligible again; forced passes were never suppressed.
        harness.repository.noteUpdated(event)
        let didRunAfterEdit = await harness.service.runOnce(force: false)
        #expect(didRunAfterEdit)
        #expect(inferenceCalls.value == 1)
    }

    @Test func stampsFetchedEventsOnlyAfterSuccess() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let event = harness.insertUpcomingEvent()

        // The model "fetches" via the tool, then the call fails: no stamp.
        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_calendar_events" }) {
                _ = try await fetch.execute(arguments: [:])
            }
            throw ToolError.executionFailed("simulated network failure")
        }
        // Assertions read through a FRESH context: the service stamps in its
        // own `ModelContext`, so the harness's cached instance would be stale.
        func freshStamp() -> Date? {
            CalendarRepository(modelContext: ModelContext(harness.container))
                .event(withID: event.id)?.lastReviewedAt
        }

        let failed = await harness.service.runOnce(force: true)
        #expect(!failed)
        #expect(freshStamp() == nil)

        // Success: the fetched event is stamped.
        harness.service.completeProvider = { _, _, _, tools in
            if let fetch = tools.first(where: { $0.name == "fetch_calendar_events" }) {
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
        harness.insertUpcomingEvent()

        let offeredTools = LockedValue<[String]>([])
        harness.service.completeProvider = { _, _, _, tools in
            offeredTools.update { $0 = tools.map(\.name).sorted() }
            return ""
        }
        _ = await harness.service.runOnce(force: true)
        #expect(offeredTools.value == ["fetch_calendar_events", "notify_user_about_events"])
    }
}
