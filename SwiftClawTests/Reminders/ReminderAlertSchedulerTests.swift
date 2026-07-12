import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import SwiftClaw

@MainActor
struct ReminderAlertSchedulerTests {
    /// Dates are built relative to the real clock: `scheduleReminderAlert`
    /// sanity-checks `fireDate > .now` against the live clock, so pinning a
    /// fictional "now" would silently drop every booking.
    private static let now = Date.now

    private static func hoursFromNow(_ hours: Double) -> Date {
        now.addingTimeInterval(hours * 3600)
    }

    /// Local start-of-day `days` from now — date-only due dates store local
    /// midnight. Two days out keeps every derived morning fire date safely in
    /// the future no matter what time the suite runs.
    private static func startOfDay(daysFromNow days: Int) -> Date {
        Calendar.current.startOfDay(for: now.addingTimeInterval(Double(days) * 24 * 3600))
    }

    private struct Harness {
        let container: ModelContainer
        let repository: ReminderRepository
        let spy: NotificationSchedulingSpy
        let service: AppNotificationService
        let scheduler: ReminderAlertScheduler
        let fixture: UserDefaultsFixture

        @MainActor
        init() throws {
            let schema = Schema([Reminder.self, ReminderList.self])
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            repository = ReminderRepository(modelContext: ModelContext(container))
            fixture = try UserDefaultsFixture()
            // Master + reminder-alert notification settings on.
            fixture.defaults.set(true, forKey: SettingsKeys.notificationsEnabled)

            spy = NotificationSchedulingSpy()
            service = AppNotificationService()
            service.configureForTesting(center: spy, userDefaults: fixture.defaults)
            service.activate()

            scheduler = ReminderAlertScheduler(notificationService: service)
            scheduler.now = { ReminderAlertSchedulerTests.now }
            // Point the scheduler's settings gates at the fixture defaults
            // (the production defaults read `.standard`).
            let defaults = fixture.defaults
            scheduler.alertsEnabledProvider = {
                SettingsStorage.areReminderAlertNotificationsEnabled(userDefaults: defaults)
            }
            scheduler.allDayAlertMinutesProvider = {
                SettingsStorage.loadRemindersAllDayAlertMinutes(userDefaults: defaults)
            }
        }

        @MainActor
        func reconcileAndFlush() async {
            await scheduler.reconcile(modelContainer: container)
            #if DEBUG
            await service.flushPostsForTesting()
            #endif
        }

        func cleanup() {
            fixture.cleanup()
        }
    }

    @Test func schedulesAlertForTimedReminder() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))

        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
        let request = try #require(harness.spy.addedRequests.first)
        #expect(request.identifier.hasPrefix(NotificationIdentifier.reminderAlertPrefix))
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.nextTriggerDate() != nil)
        #expect(request.content.title == "Call the dentist")
    }

    @Test func dateOnlyReminderFiresAtTheConfiguredMorningTime() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Water plants",
            dueDate: Self.startOfDay(daysFromNow: 2),
            hasDueTime: false
        ))

        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
        let request = try #require(harness.spy.addedRequests.first)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        // Default morning time: 9:00 AM.
        #expect(trigger.dateComponents.hour == 9)
        #expect(trigger.dateComponents.minute == 0)
    }

    @Test func changedMorningTimeMovesTheDateOnlyFire() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        // 7:30 AM.
        SettingsStorage.saveRemindersAllDayAlertMinutes(7 * 60 + 30, userDefaults: harness.fixture.defaults)

        harness.repository.insert(Reminder(
            title: "Water plants",
            dueDate: Self.startOfDay(daysFromNow: 2),
            hasDueTime: false
        ))

        await harness.reconcileAndFlush()
        let request = try #require(harness.spy.addedRequests.first)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.dateComponents.hour == 7)
        #expect(trigger.dateComponents.minute == 30)
    }

    @Test func datelessRemindersAreNotBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(title: "Someday: learn the theremin"))

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func overdueRemindersAreNotBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Already late",
            dueDate: Self.hoursFromNow(-2),
            hasDueTime: true
        ))

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func dueDatesPastTheHorizonAreNotBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Far future",
            dueDate: Self.hoursFromNow(10 * 24),
            hasDueTime: true
        ))

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func reconcileIsIdempotent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))

        await harness.reconcileAndFlush()
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)
    }

    @Test func completingAOneOffRetiresItsAlert() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let reminder = harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        harness.repository.complete(reminder)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    @Test func uncompletingRestoresTheAlert() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let reminder = harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        await harness.reconcileAndFlush()
        let originalIdentifier = try #require(harness.spy.addedRequests.first?.identifier)

        harness.repository.complete(reminder)
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)

        harness.repository.uncomplete(reminder)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
        #expect(harness.spy.addedRequests.first?.identifier == originalIdentifier)
    }

    @Test func completingARecurringMasterRollsTheAlertForward() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // Daily fixed-schedule master due in 6h; completing advances the
        // master's dueDate one day, so the identifier (which embeds the fire
        // date) must change.
        let reminder = harness.repository.insert(Reminder(
            title: "Take medication",
            dueDate: Self.hoursFromNow(6),
            hasDueTime: true,
            recurrenceRuleString: "FREQ=DAILY"
        ))
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)
        let firstIdentifier = try #require(harness.spy.addedRequests.first?.identifier)

        harness.repository.complete(reminder)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
        let secondIdentifier = try #require(harness.spy.addedRequests.first?.identifier)
        #expect(secondIdentifier != firstIdentifier)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self) == [firstIdentifier])
    }

    @Test func completionLogRowsAreNeverBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // A recurring master completed once: the detached log row carries the
        // original occurrence but must not produce an alert of its own.
        let reminder = harness.repository.insert(Reminder(
            title: "Take medication",
            dueDate: Self.hoursFromNow(6),
            hasDueTime: true,
            recurrenceRuleString: "FREQ=DAILY"
        ))
        harness.repository.complete(reminder)

        await harness.reconcileAndFlush()
        // Only the advanced master's next occurrence is booked.
        #expect(harness.spy.addedRequests.count == 1)
    }

    @Test func budgetKeepsSoonestAlerts() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // 20 due-dated reminders in the window; only the soonest
        // `maximumPendingAlerts` get booked.
        for index in 0..<20 {
            harness.repository.insert(Reminder(
                title: "Reminder \(index)",
                dueDate: Self.hoursFromNow(1 + Double(index)),
                hasDueTime: true
            ))
        }

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == ReminderAlertScheduler.maximumPendingAlerts)
        let titles = Set(harness.spy.addedRequests.map(\.content.title))
        #expect(titles.contains("Reminder 0"))
        #expect(!titles.contains("Reminder 19"))
    }

    @Test func disabledReminderAlertSettingSuppressesBooking() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsReminderAlertsEnabled)

        harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func disablingAlertsClearsAlreadyBookedRequests() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        // Turning the setting off must retire the already-booked request,
        // not just stop new ones.
        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsReminderAlertsEnabled)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    @Test func dateOnlyFireTimeHoldsWallClockAcrossDSTTransition() throws {
        // US spring-forward: 2026-03-08 in Chicago skips 2:00–3:00 AM, so
        // "9 * 60 minutes of elapsed time after midnight" lands at 10:00 AM
        // wall clock. The fire date must be built from components instead.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let dueDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))

        let fireDate = ReminderAlertScheduler.fireDate(
            forDueDate: dueDate,
            hasDueTime: false,
            allDayAlertMinutes: 9 * 60,
            calendar: calendar
        )

        let components = calendar.dateComponents([.hour, .minute], from: fireDate)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
    }

    @Test func editingTheTitleRebooksTheAlertWithFreshContent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let reminder = harness.repository.insert(Reminder(
            title: "Old title",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        await harness.reconcileAndFlush()
        let originalIdentifier = try #require(harness.spy.addedRequests.first?.identifier)

        reminder.title = "New title"
        harness.repository.noteUpdated(reminder)
        await harness.reconcileAndFlush()

        // Same reminder, same fire date — but the stale banner text must be
        // replaced, so the request is rebooked under a fresh identifier.
        #expect(harness.spy.addedRequests.count == 1)
        let request = try #require(harness.spy.addedRequests.first)
        #expect(request.content.title == "New title")
        #expect(request.identifier != originalIdentifier)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self) == [originalIdentifier])
    }

    @Test func reconcileAfterClearAllRebooksPromptly() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Call the dentist",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        // Feature toggled off and immediately back on: reconcile must wait
        // out the in-flight clear instead of reading identifiers the clear is
        // about to delete (and then never rebooking them).
        harness.scheduler.clearAllPendingAlerts()
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
    }

    @Test func alertBodyDistinguishesTimedFromDateOnly() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        harness.repository.insert(Reminder(
            title: "Timed",
            dueDate: Self.hoursFromNow(30),
            hasDueTime: true
        ))
        harness.repository.insert(Reminder(
            title: "Date-only",
            dueDate: Self.startOfDay(daysFromNow: 2),
            hasDueTime: false
        ))

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 2)
        let bodies = Dictionary(
            uniqueKeysWithValues: harness.spy.addedRequests.map { ($0.content.title, $0.content.body) }
        )
        // Timed bodies carry a clock time; date-only bodies carry just the day.
        #expect(bodies["Timed"]?.contains(":") == true)
        #expect(bodies["Date-only"]?.contains(":") == false)
    }
}
