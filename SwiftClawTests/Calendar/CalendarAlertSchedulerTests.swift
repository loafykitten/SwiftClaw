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
            // Scheduled alerts also require their feature to be on.
            fixture.defaults.set(true, forKey: SettingsKeys.calendarEnabled)

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

    @Test func editingTheTitleRebooksTheAlertWithFreshContent() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }

        let event = harness.repository.insert(CalendarEvent(
            title: "Old title",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()
        let originalIdentifier = try #require(harness.spy.addedRequests.first?.identifier)

        event.title = "New title"
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()

        // Same event, same fire date — but the stale banner text must be
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

        let event = harness.repository.insert(CalendarEvent(
            title: "Call the dentist",
            startDate: Self.hoursFromNow(30),
            endDate: Self.hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)
        await harness.reconcileAndFlush()
        #expect(harness.spy.addedRequests.count == 1)

        // Feature toggled off and immediately back on: reconcile must wait
        // out the in-flight clear instead of reading identifiers the clear is
        // about to delete (and then never rebooking them).
        harness.scheduler.clearAllPendingAlerts()
        await harness.reconcileAndFlush()

        #expect(harness.spy.addedRequests.count == 1)
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

    // MARK: - Feature shutdown vs. in-flight posts

    /// Polls (yielding) until `condition` holds; posts run in unstructured
    /// tasks the test can't await directly.
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
    }

    @MainActor
    private static func insertAlarmedEvent(_ harness: Harness) {
        let event = harness.repository.insert(CalendarEvent(
            title: "Dentist",
            startDate: hoursFromNow(30),
            endDate: hoursFromNow(31),
            calendar: harness.repository.defaultCalendar()
        ))
        event.alarms = [CalendarAlarmPayload(offsetSeconds: -900)]
        harness.repository.noteUpdated(event)
    }

    /// A post suspended in its authorization lookup when Calendar is
    /// switched off must not book the alert once it resumes.
    @Test func postSuspendedAcrossFeatureShutdownDoesNotBook() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        Self.insertAlarmedEvent(harness)
        // Let activation's own lookup finish first, so the only suspended
        // lookup is the post's.
        await Self.waitUntil { harness.spy.authorizationLookupCount > 0 }
        harness.spy.suspendsAuthorizationLookups = true

        await harness.scheduler.reconcile(modelContainer: harness.container)
        await Self.waitUntil { harness.spy.suspendedLookupCount > 0 }
        #expect(harness.spy.suspendedLookupCount == 1)

        // Feature off (ContentView's onChange path), then the post resumes.
        harness.fixture.defaults.set(false, forKey: SettingsKeys.calendarEnabled)
        harness.scheduler.clearAllPendingAlerts()
        harness.spy.resumeSuspendedLookups()
        await harness.service.flushPostsForTesting()

        #expect(harness.spy.addedRequests.isEmpty)
    }

    /// A post already past its gate (suspended inside `add`) when the clear
    /// starts lands first and is then removed, instead of surviving it.
    @Test func clearWaitsForAddsAlreadyInFlight() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        Self.insertAlarmedEvent(harness)
        harness.spy.suspendsAdds = true

        await harness.scheduler.reconcile(modelContainer: harness.container)
        await Self.waitUntil { harness.spy.suspendedAddCount > 0 }
        #expect(harness.spy.suspendedAddCount == 1)

        harness.fixture.defaults.set(false, forKey: SettingsKeys.calendarEnabled)
        harness.scheduler.clearAllPendingAlerts()
        harness.spy.resumeSuspendedAdds()
        await harness.service.flushPostsForTesting()
        await Self.waitUntil { !harness.spy.removedPendingIdentifierBatches.isEmpty }

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    /// Turning the alert toggle off runs ordinary reconciliation, not the
    /// feature-shutdown clear. A post still suspended inside `add` from the
    /// pass before must land first and be removed, not survive the disable.
    @Test func disablingAlertsWaitsForAddsAlreadyInFlight() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        Self.insertAlarmedEvent(harness)
        harness.spy.suspendsAdds = true

        await harness.scheduler.reconcile(modelContainer: harness.container)
        await Self.waitUntil { harness.spy.suspendedAddCount > 0 }
        #expect(harness.spy.suspendedAddCount == 1)

        // Toggle off (NotificationSettingsView → settingsDidChange path).
        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsCalendarAlertsEnabled)
        let waitsBefore = harness.service.inFlightPostWaitCount
        let lookupsBefore = harness.spy.pendingRequestsLookupCount
        let disable = Task { await harness.scheduler.reconcile(modelContainer: harness.container) }
        // The disable pass must start draining before it lists pending
        // requests; without the drain it would read the still-empty list.
        await Self.waitUntil {
            harness.service.inFlightPostWaitCount > waitsBefore
                || harness.spy.pendingRequestsLookupCount > lookupsBefore
        }
        #expect(harness.service.inFlightPostWaitCount > waitsBefore)
        #expect(harness.spy.pendingRequestsLookupCount == lookupsBefore)
        harness.spy.resumeSuspendedAdds()
        await disable.value
        await harness.service.flushPostsForTesting()

        #expect(harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.flatMap(\.self).count == 1)
    }

    /// Alerts switched back on while the disable pass is still draining: the
    /// newer enabled pass books, and the stale disable pass must not then
    /// remove what it booked.
    @Test func staleDisablePassDoesNotUndoAReenable() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        Self.insertAlarmedEvent(harness)
        harness.spy.suspendsAdds = true

        await harness.scheduler.reconcile(modelContainer: harness.container)
        await Self.waitUntil { harness.spy.suspendedAddCount > 0 }
        #expect(harness.spy.suspendedAddCount == 1)

        harness.fixture.defaults.set(false, forKey: SettingsKeys.notificationsCalendarAlertsEnabled)
        let waitsBefore = harness.service.inFlightPostWaitCount
        let disable = Task { await harness.scheduler.reconcile(modelContainer: harness.container) }
        await Self.waitUntil { harness.service.inFlightPostWaitCount > waitsBefore }
        #expect(harness.service.inFlightPostWaitCount > waitsBefore)

        // Back on before the drain finishes; this pass's own add lands.
        harness.fixture.defaults.set(true, forKey: SettingsKeys.notificationsCalendarAlertsEnabled)
        harness.spy.suspendsAdds = false
        await harness.scheduler.reconcile(modelContainer: harness.container)
        await Self.waitUntil { !harness.spy.addedRequests.isEmpty }
        #expect(!harness.spy.addedRequests.isEmpty)

        harness.spy.resumeSuspendedAdds()
        await disable.value
        await harness.service.flushPostsForTesting()

        #expect(!harness.spy.addedRequests.isEmpty)
        #expect(harness.spy.removedPendingIdentifierBatches.isEmpty)
    }
}
