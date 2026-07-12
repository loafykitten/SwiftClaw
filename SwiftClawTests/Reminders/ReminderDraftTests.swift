import Foundation
import SwiftData
@testable import SwiftClaw
import Testing

@MainActor
struct ReminderDraftTests {
    private static func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Reminder.self, ReminderList.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func roundTripsThroughModel() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let list = repository.defaultList()

        var draft = ReminderDraft(listID: list.id)
        draft.title = "  Buy milk  "
        draft.notes = "2%"
        draft.urlString = "https://example.com"
        draft.dueDateMode = .dateTime
        draft.dueDate = Self.date(2026, 6, 5, 9)
        draft.priority = .high
        draft.isFlagged = true
        draft.checklist = [ReminderChecklistItem(text: "Check fridge")]

        let reminder = Reminder()
        draft.apply(to: reminder, in: repository)
        repository.insert(reminder)

        #expect(reminder.title == "Buy milk")
        #expect(reminder.notes == "2%")
        #expect(reminder.urlString == "https://example.com")
        #expect(reminder.dueDate == Self.date(2026, 6, 5, 9))
        #expect(reminder.hasDueTime)
        #expect(reminder.timeZoneIdentifier == TimeZone.current.identifier)
        #expect(reminder.priority == .high)
        #expect(reminder.isFlagged)
        #expect(reminder.checklist.map(\.text) == ["Check fridge"])
        #expect(reminder.list?.id == list.id)

        let reloaded = ReminderDraft(from: reminder)
        #expect(reloaded.title == "Buy milk")
        #expect(reloaded.dueDateMode == .dateTime)
        #expect(reloaded.priority == .high)
        #expect(reloaded.checklist.map(\.text) == ["Check fridge"])
    }

    @Test func dateOnlyModeNormalizesAndFloats() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        var draft = ReminderDraft(listID: nil)
        draft.title = "File taxes"
        draft.dueDateMode = .date
        draft.dueDate = Self.date(2026, 4, 15, 15)

        let reminder = Reminder()
        draft.apply(to: reminder, in: repository)

        #expect(reminder.dueDate == Calendar.current.startOfDay(for: Self.date(2026, 4, 15)))
        #expect(!reminder.hasDueTime)
        #expect(reminder.timeZoneIdentifier == nil)

        #expect(ReminderDraft(from: reminder).dueDateMode == .date)
    }

    @Test func clearingDueDateClearsStoredFields() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let reminder = repository.insert(Reminder(
            title: "Was scheduled",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            timeZoneIdentifier: TimeZone.current.identifier
        ))

        var draft = ReminderDraft(from: reminder)
        draft.dueDateMode = .none
        draft.apply(to: reminder, in: repository)

        #expect(reminder.dueDate == nil)
        #expect(!reminder.hasDueTime)
        #expect(reminder.timeZoneIdentifier == nil)
    }

    @Test func repeatModesAreMutuallyExclusiveOnTheModel() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let reminder = repository.insert(Reminder(title: "Chore", dueDate: Self.date(2026, 6, 5)))

        var draft = ReminderDraft(from: reminder)
        draft.repeatMode = .schedule
        draft.rule = .weekly
        draft.apply(to: reminder, in: repository)
        #expect(reminder.recurrenceRuleString == RecurrenceRule.weekly.rruleString)
        #expect(reminder.afterCompletionRepeat == nil)

        draft.repeatMode = .afterCompletion
        draft.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 3, unit: .day)
        draft.apply(to: reminder, in: repository)
        #expect(reminder.recurrenceRuleString == nil)
        #expect(reminder.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 3, unit: .day))

        draft.repeatMode = .never
        draft.apply(to: reminder, in: repository)
        #expect(reminder.recurrenceRuleString == nil)
        #expect(reminder.afterCompletionRepeat == nil)
    }

    @Test func validationRequiresTitleAndAnchoredRepeat() {
        var draft = ReminderDraft(listID: nil)
        #expect(!draft.isValid)

        draft.title = "Water plants"
        #expect(draft.isValid)

        draft.repeatMode = .afterCompletion
        #expect(!draft.isValid) // repeat without a due date has no anchor

        draft.dueDateMode = .date
        #expect(draft.isValid)
    }

    @Test func editingLoadsExistingRecurrence() throws {
        let repository = try ReminderRepository(modelContext: ModelContext(Self.inMemoryContainer()))
        let reminder = repository.insert(Reminder(
            title: "Weekly report",
            dueDate: Self.date(2026, 6, 5, 9),
            hasDueTime: true,
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=FR"
        ))

        let draft = ReminderDraft(from: reminder)
        #expect(draft.repeatMode == .schedule)
        #expect(draft.rule?.frequency == .weekly)
    }
}
