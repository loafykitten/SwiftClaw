import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import SwiftClaw

@MainActor
struct CalendarAlertSchedulerTests {
    /// Dates are built relative to the real clock: `scheduleEventAlert`
    /// sanity-checks `fireDate > .now` against the live clock, so pinning a
    /// fictional "now" would silently drop every booking.
    private static let now = Date.now

    private static func hoursFromNow(_ hours: Double) -> Date {
        now.addingTimeInterval(hours * 3600)
    }

    private struct Harness {
        let container: ModelContainer
        let repository: CalendarRepository
        let spy: NotificationSchedulingSpy
        let service: AppNotificationService
        let scheduler: CalendarAlertScheduler
        let fixture: UserDefaultsFixture

        @MainActor
        init() throws {
            let schema = Schema([CalendarEvent.self, UserCalendar.self])
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
            repository = CalendarRepository(modelContext: ModelContext(container))
            fixture = try UserDefaultsFixture()
            // Master + calendar-alert notification settings on.
            fixture.defaults.set(true, forKey: SettingsKeys.notificationsEnabled)

            spy = NotificationSchedulingSpy()
            service = AppNotificationService()
            service.configureForTesting(center: spy, userDefaults: fixture.defaults)
            service.activate()

            scheduler = CalendarAlertScheduler(notificationService: service)
            scheduler.now = { CalendarAlertSchedulerTests.now }
            // Point the scheduler's settings gate at the fixture defaults
            // (the production default reads `.standard`).
            let defaults = fixture.defaults
            scheduler.alertsEnabledProvider = {
                SettingsStorage.areCalendarAlertNotificationsEnabled(userDefaults: defaults)
            }
            // Deterministic shared-mode budget; the production default reads
            // the real reminders settings.
            scheduler.reminderAlertsActiveProvider = { true }
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

    @Test func schedulesAlarmsForUpcomingOccurrences() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
        let request = try #require(harness.spy.addedRequests.first)
        #expect(request.identifier.hasPrefix(NotificationIdentifier.calendarAlertPrefix))
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.nextTriggerDate() != nil)
        #expect(request.content.title == "Dentist")
    }

    @Test func expandsRecurringAlarmsAcrossTheWindow() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // Daily series anchored 9 days ago, 3h into the day relative to now,
        // with a 15-minute-before alarm. Window [now, now+7d) holds exactly 7
        // occurrences (now+3h … now+6d3h), all with future fire dates.
        let event = harness.repository.insert(CalendarEvent(
            title: "Standup",
            startDate: Self.hoursFromNow(-9 * 24 + 3),
            endDate: Self.hoursFromNow(-9 * 24 + 3.25),
            timeZoneIdentifier: "UTC",
            recurrenceRuleString: "FREQ=DAILY",
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 7)
    }

    @Test func removesStaleAlarmsWhenAlarmIsCleared() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        event.alarms = []
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    @Test func reconcileIsIdempotent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)
    }

    @Test func pastFireDatesAreNotBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // Started an hour ago; the -15m alarm is in the past, but the
        // occurrence still intersects the window.
        let event = harness.repository.insert(CalendarEvent(
            title: "Already happening",
            startDate: Self.hoursFromNow(-1),
            endDate: Self.hoursFromNow(1),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func budgetKeepsSoonestAlarms() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // 60 alarms in the window; only the soonest `maximumPendingAlerts`
        // get booked.
        let calendar = harness.repository.defaultCalendar()
        for index in 0..<60 {
            let start = Self.hoursFromNow(1 + Double(index) * 0.5)
            let event = harness.repository.insert(CalendarEvent(
                title: "Event \(index)",
                startDate: start,
                endDate: start.addingTimeInterval(900),
                calendar: calendar
            ))
            event.alarms = [CalendarAlarmPayload(offsetSeconds: 0)]
            harness.repository.noteUpdated(event)
        }

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == CalendarAlertScheduler.maximumPendingAlerts)
        let titles = Set(harness.spy.addedRequests.map(\.content.title))
        #expect(titles.contains("Event 0"))
        #expect(!titles.contains("Event 59"))
    }

    /// With reminder alerts unable to book (feature or toggle off) the
    /// calendar keeps the full standalone budget instead of reserving slots
    /// nothing will use.
    @Test func budgetExpandsWhileReminderAlertsAreIdle() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.scheduler.reminderAlertsActiveProvider = { false }

        let calendar = harness.repository.defaultCalendar()
        for index in 0..<60 {
            let start = Self.hoursFromNow(1 + Double(index) * 0.5)
            let event = harness.repository.insert(CalendarEvent(
                title: "Event \(index)",
                startDate: start,
                endDate: start.addingTimeInterval(900),
                calendar: calendar
            ))
            event.alarms = [CalendarAlarmPayload(offsetSeconds: 0)]
            harness.repository.noteUpdated(event)
        }

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == CalendarAlertScheduler.standaloneMaximumPendingAlerts)
    }

    @Test func disabledCalendarAlertSettingSuppressesBooking() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsCalendarAlertsEnabled)

        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }

    @Test func disablingAlertsClearsAlreadyBookedRequests() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        // Turning the setting off must retire the already-booked request,
        // not just stop new ones.
        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsCalendarAlertsEnabled)
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    @Test func longLeadAlarmInsideHorizonIsBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // Event 10 days out with a one-week-before alarm: the occurrence is
        // past the horizon but the fire date (in ~3 days) is inside it.
        let event = harness.repository.insert(CalendarEvent(
            title: "Conference",
            startDate: Self.hoursFromNow(10 * 24),
            endDate: Self.hoursFromNow(10 * 24 + 1),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -7 * 24 * 3600)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)
    }

    @Test func fireDatesPastTheHorizonAreNotBooked() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        // Occurrence inside the window, but a positive offset pushes the
        // fire date past the horizon — book it on a later pass instead.
        let event = harness.repository.insert(CalendarEvent(
            title: "Follow-up",
            startDate: Self.hoursFromNow(48),
            endDate: Self.hoursFromNow(49),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: 6 * 24 * 3600)]
        harness.repository.noteUpdated(event)

        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.isEmpty)
    }
}
