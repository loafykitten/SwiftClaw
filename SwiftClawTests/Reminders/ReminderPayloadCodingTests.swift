import Foundation
@testable import SwiftClaw
import Testing

@MainActor
struct ReminderPayloadCodingTests {
    @Test func checklistRoundTripsAndEmptyClearsData() {
        let reminder = Reminder(title: "Groceries")
        let itemID = UUID()
        reminder.checklist = [
            ReminderChecklistItem(id: itemID, text: "Milk", isDone: true),
            ReminderChecklistItem(text: "Coffee"),
        ]

        #expect(reminder.checklistData != nil)
        #expect(reminder.checklist.count == 2)
        #expect(reminder.checklist.first?.id == itemID)
        #expect(reminder.checklist.first?.isDone == true)

        reminder.checklist = []
        #expect(reminder.checklistData == nil)
        #expect(reminder.checklist.isEmpty)
    }

    @Test func afterCompletionRepeatRoundTrips() {
        let reminder = Reminder(title: "Water plants")
        reminder.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: 2, unit: .week)

        #expect(reminder.afterCompletionRepeatData != nil)
        #expect(reminder.afterCompletionRepeat == ReminderAfterCompletionRepeat(count: 2, unit: .week))

        reminder.afterCompletionRepeat = nil
        #expect(reminder.afterCompletionRepeatData == nil)
    }

    @Test func priorityBucketsImportedRawValues() {
        let reminder = Reminder(title: "Priority")
        reminder.priorityRawValue = 2
        #expect(reminder.priority == .high)

        reminder.priorityRawValue = 7
        #expect(reminder.priority == .low)

        reminder.priorityRawValue = 0
        #expect(reminder.priority == .none)

        reminder.priority = .medium
        #expect(reminder.priorityRawValue == 5)
    }
}
