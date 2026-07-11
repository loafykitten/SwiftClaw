import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct CalendarQuickEntryServiceTests {
    private static func makeService(response: String) throws -> (CalendarQuickEntryService, UserDefaultsFixture) {
        let fixture = try UserDefaultsFixture()
        fixture.defaults.set("test-model", forKey: SettingsKeys.clawModel)
        let service = CalendarQuickEntryService(userDefaults: fixture.defaults)
        service.completeProvider = { _, _, _, _ in response }
        return (service, fixture)
    }

    @Test func parsesCleanJSONResponse() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Lunch with Sam", "start": "2026-07-11T13:00:00Z", "end": "2026-07-11T14:00:00Z", "location": "Blue Door Cafe"}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "Lunch with Sam tomorrow 1pm", calendarID: nil)
        #expect(draft.title == "Lunch with Sam")
        #expect(draft.location == "Blue Door Cafe")
        #expect(draft.end.timeIntervalSince(draft.start) == 3600)
        #expect(!draft.isAllDay)
        #expect(draft.rule == nil)
    }

    @Test func parsesFencedResponseWithProse() async throws {
        let (service, fixture) = try Self.makeService(response: """
        Here's the event you asked for:
        ```json
        {"title": "Standup", "start": "2026-07-13T09:15:00Z", "rrule": "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"}
        ```
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "standup every weekday 9:15", calendarID: nil)
        #expect(draft.title == "Standup")
        #expect(draft.rule?.rruleString == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        // No end supplied → 1-hour default from the draft initializer.
        #expect(draft.end.timeIntervalSince(draft.start) == 3600)
    }

    @Test func allDayEventsSpanTheFullDay() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Trip to Kyoto", "start": "2026-08-03T00:00:00Z", "all_day": true}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "Trip to Kyoto Aug 3", calendarID: nil)
        #expect(draft.isAllDay)
        #expect(draft.end.timeIntervalSince(draft.start) == 24 * 3600)
    }

    @Test func throwsOnGarbageResponse() async throws {
        let (service, fixture) = try Self.makeService(response: "Sorry, I can't help with that.")
        defer { fixture.cleanup() }
        await #expect(throws: CalendarQuickEntryService.QuickEntryError.self) {
            _ = try await service.draft(from: "???", calendarID: nil)
        }
    }

    @Test func throwsWhenModelNotConfigured() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let service = CalendarQuickEntryService(userDefaults: fixture.defaults)
        await #expect(throws: CalendarQuickEntryService.QuickEntryError.self) {
            _ = try await service.draft(from: "Lunch tomorrow", calendarID: nil)
        }
    }

    @Test func ignoresEndBeforeStart() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Weird", "start": "2026-07-11T13:00:00Z", "end": "2026-07-11T12:00:00Z"}
        """)
        defer { fixture.cleanup() }
        let draft = try await service.draft(from: "weird", calendarID: nil)
        #expect(draft.end.timeIntervalSince(draft.start) == 3600)
    }
}
