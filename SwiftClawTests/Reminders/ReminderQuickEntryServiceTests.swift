import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct ReminderQuickEntryServiceTests {
    private static func makeService(response: String) throws -> (ReminderQuickEntryService, UserDefaultsFixture) {
        let fixture = try UserDefaultsFixture()
        fixture.defaults.set("test-model", forKey: SettingsKeys.clawModel)
        let service = ReminderQuickEntryService(userDefaults: fixture.defaults)
        service.completeProvider = { _, _, _, _ in response }
        return (service, fixture)
    }

    @Test func parsesTimedReminderWithPriorityAndList() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Email Priya about the invoice", "due": "2026-07-12T09:00:00-05:00", "has_time": true, "list": "Work", "priority": "high"}
        """)
        defer { fixture.cleanup() }
        let workID = UUID()

        let draft = try await service.draft(
            from: "email priya about the invoice tomorrow 9am on work, urgent",
            lists: [(id: UUID(), name: "Groceries"), (id: workID, name: "Work")]
        )
        #expect(draft.title == "Email Priya about the invoice")
        #expect(draft.dueDateMode == .dateTime)
        #expect(draft.dueDate == Date(timeIntervalSince1970: 1_783_864_800))
        #expect(draft.listID == workID)
        #expect(draft.priority == .high)
        #expect(draft.repeatMode == .never)
    }

    @Test func dateOnlyDueLandsAtLocalMidnight() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Renew passport", "due": "2026-08-03", "has_time": false}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "renew passport aug 3", lists: [])
        #expect(draft.dueDateMode == .date)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 3))
        #expect(draft.dueDate == expected)
        #expect(draft.priority == .none)
        #expect(draft.listID == nil)
    }

    @Test func datelessPhraseYieldsDatelessDraft() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Buy milk"}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "buy milk", lists: [])
        #expect(draft.title == "Buy milk")
        #expect(!draft.hasDueDate)
        #expect(draft.isValid)
    }

    @Test func parsesFencedScheduleRepeat() async throws {
        let (service, fixture) = try Self.makeService(response: """
        Here's your reminder:
        ```json
        {"title": "Take out recycling", "due": "2026-07-13", "rrule": "FREQ=WEEKLY;BYDAY=MO"}
        ```
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "recycling every monday", lists: [])
        #expect(draft.repeatMode == .schedule)
        #expect(draft.rule?.rruleString == "FREQ=WEEKLY;BYDAY=MO")
    }

    @Test func parsesAfterCompletionRepeat() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Water the plants", "due": "2026-07-12", "repeat_after": {"count": 2, "unit": "week"}}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "water plants every 2 weeks after finishing", lists: [])
        #expect(draft.repeatMode == .afterCompletion)
        #expect(draft.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 2, unit: .week))
        #expect(draft.rule == nil)
    }

    @Test func repeatWithoutDueDateIsDroppedSoDraftStaysSaveable() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Stretch", "rrule": "FREQ=DAILY"}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "stretch daily", lists: [])
        #expect(draft.repeatMode == .never)
        #expect(draft.rule == nil)
        #expect(draft.isValid)
    }

    @Test func unknownListNameLeavesListNilForTheDefault() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Pick up parcel", "list": "Errands"}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "pick up parcel", lists: [(id: UUID(), name: "Work")])
        #expect(draft.listID == nil)
    }

    @Test func listMatchIsCaseInsensitive() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Buy oat milk", "list": "groceries"}
        """)
        defer { fixture.cleanup() }
        let groceriesID = UUID()

        let draft = try await service.draft(from: "oat milk", lists: [(id: groceriesID, name: "Groceries")])
        #expect(draft.listID == groceriesID)
    }

    @Test func throwsOnGarbageResponse() async throws {
        let (service, fixture) = try Self.makeService(response: "Sorry, I can't help with that.")
        defer { fixture.cleanup() }
        await #expect(throws: ReminderQuickEntryService.QuickEntryError.self) {
            _ = try await service.draft(from: "???", lists: [])
        }
    }

    @Test func throwsWhenModelNotConfigured() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let service = ReminderQuickEntryService(userDefaults: fixture.defaults)
        await #expect(throws: ReminderQuickEntryService.QuickEntryError.self) {
            _ = try await service.draft(from: "buy milk", lists: [])
        }
    }

    @Test func blankTitleThrowsSoThePhraseFallbackRuns() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "  ", "due": "2026-07-12"}
        """)
        defer { fixture.cleanup() }
        await #expect(throws: ReminderQuickEntryService.QuickEntryError.self) {
            _ = try await service.draft(from: "something important", lists: [])
        }
    }

    @Test func offsetLessTimedDueParsesAsLocalTime() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Call the dentist", "due": "2026-07-12T09:00:00", "has_time": true}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "call the dentist tomorrow 9am", lists: [])
        #expect(draft.dueDateMode == .dateTime)
        let expected = Calendar.current.date(
            from: DateComponents(year: 2026, month: 7, day: 12, hour: 9)
        )
        #expect(draft.dueDate == expected)
    }

    @Test func unreadableTimedDueDegradesToDatelessNotDateOnly() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Standup", "due": "2026-07-12T09", "has_time": true}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "standup tomorrow at 9", lists: [])
        #expect(!draft.hasDueDate)
    }

    @Test func impossibleDateOnlyDegradesToDateless() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Pay rent", "due": "2026-02-30"}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "pay rent feb 30", lists: [])
        #expect(!draft.hasDueDate)
    }

    @Test func malformedDueDegradesToDateless() async throws {
        let (service, fixture) = try Self.makeService(response: """
        {"title": "Call the bank", "due": "next tuesday", "has_time": false}
        """)
        defer { fixture.cleanup() }

        let draft = try await service.draft(from: "call the bank next tuesday", lists: [])
        #expect(!draft.hasDueDate)
        #expect(draft.title == "Call the bank")
    }
}
