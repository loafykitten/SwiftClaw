#if DEBUG
import Foundation
import SwiftData

/// Seeds a week of calendar events plus a couple of reminder lists when
/// launched with `-SwiftClawSeedSampleCalendar`, so simulator/UI runs (and
/// README screenshots) can show the Calendar and Reminders tabs without
/// importing real data. Sibling of `SampleChatSeeder` and
/// `SampleEmailSeeder`; DEBUG-only tooling, never compiled into release.
@MainActor
enum SampleCalendarSeeder {
    static func seedIfRequested(into container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-SwiftClawSeedSampleCalendar") else { return }

        let context = container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<UserCalendar>())) ?? 0) == 0,
              ((try? context.fetchCount(FetchDescriptor<ReminderList>())) ?? 0) == 0 else { return }

        UserDefaults.standard.set(true, forKey: SettingsKeys.calendarEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKeys.remindersEnabled)
        // The seeded data stands in for an import, so skip the set-up sheets.
        UserDefaults.standard.set(true, forKey: SettingsKeys.calendarHasCompletedOnboarding)
        UserDefaults.standard.set(true, forKey: SettingsKeys.remindersHasCompletedOnboarding)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let work = UserCalendar(name: "Work", colorHex: "#0A84FF", sortOrder: 0)
        let personal = UserCalendar(name: "Personal", colorHex: "#30D158", sortOrder: 1)
        context.insert(work)
        context.insert(personal)

        func insertEvent(
            _ title: String,
            _ start: Date,
            hours: Double,
            in userCalendar: UserCalendar,
            location: String? = nil,
            recurrence: String? = nil
        ) {
            context.insert(CalendarEvent(
                title: title,
                startDate: start,
                endDate: start.addingTimeInterval(hours * 3600),
                locationText: location,
                recurrenceRuleString: recurrence,
                calendar: userCalendar
            ))
        }

        insertEvent("Standup", at(0, 9, 30), hours: 0.25, in: work, recurrence: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        insertEvent("Q3 planning call", at(0, 11), hours: 1, in: work, location: "Zoom")
        insertEvent("Lunch with Priya", at(0, 12, 30), hours: 1, in: personal, location: "Ramen Kaze")
        insertEvent("Design review", at(1, 14), hours: 1.5, in: work, location: "Room 4B")
        insertEvent("Climbing", at(1, 18, 30), hours: 2, in: personal, location: "Bouldering gym")
        insertEvent("1:1 with Sam", at(2, 10), hours: 0.5, in: work)
        insertEvent("Dentist", at(3, 8, 30), hours: 1, in: personal)
        insertEvent("Release cut", at(3, 15), hours: 1, in: work)
        insertEvent("Dinner Saturday", at(5, 19), hours: 2, in: personal, location: "New ramen place by the park")
        context.insert(CalendarEvent(
            title: "Farmers market",
            startDate: calendar.date(byAdding: .day, value: 6, to: today) ?? today,
            endDate: calendar.date(byAdding: .day, value: 7, to: today) ?? today,
            isAllDay: true,
            calendar: personal
        ))

        let errands = ReminderList(name: "Errands", colorHex: "#FF9F0A", sortOrder: 0)
        let launch = ReminderList(name: "Launch prep", colorHex: "#BF5AF2", sortOrder: 1)
        context.insert(errands)
        context.insert(launch)

        context.insert(Reminder(title: "Pay invoice #8841", dueDate: at(4, 17), hasDueTime: true, priority: .high, isFlagged: true, list: launch))
        context.insert(Reminder(title: "Write release notes", dueDate: at(3, 12), hasDueTime: true, list: launch))
        context.insert(Reminder(title: "Record demo video", dueDate: at(2, 0), list: launch))
        context.insert(Reminder(title: "Pick up dry cleaning", dueDate: at(0, 18), hasDueTime: true, list: errands))
        context.insert(Reminder(title: "Buy coffee beans", list: errands))
        context.insert(Reminder(
            title: "Water the plants",
            dueDate: at(1, 9),
            hasDueTime: true,
            recurrenceRuleString: "FREQ=WEEKLY;BYDAY=TU,FR",
            list: errands
        ))

        try? context.save()
    }
}
#endif
