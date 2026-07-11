import Foundation
import SwiftData
import os

/// Keeps `UNUserNotificationCenter`'s pending requests in step with the
/// calendar: expands the coming week's occurrences, computes each alarm's
/// fire date, and reconciles against what's already booked (add the missing,
/// remove the stale). Identifiers are deterministic per (event, fire date),
/// so reconciliation is idempotent.
///
/// A rolling window keeps the pending count well under iOS's 64-request cap;
/// soonest alarms win when the cap bites. Re-runs on every calendar-store
/// save, after CloudKit merges, and on a periodic refresh tick.
@MainActor
final class CalendarAlertScheduler {
    static let shared = CalendarAlertScheduler()

    private static let logger = AppLog.make("calendar.alerts")

    /// How far ahead alarms are booked (by *fire date*).
    static let horizon: TimeInterval = 7 * 24 * 3600
    /// How far past the horizon occurrences are expanded so long-lead alarms
    /// ("1 week before", imported "-P4W" triggers) whose fire date falls
    /// inside the horizon still get considered.
    static let maximumAlarmLeadTime: TimeInterval = 28 * 24 * 3600
    /// Booked-alarm budget (iOS caps pending requests at 64 app-wide; leave
    /// room for the immediate notifications).
    static let maximumPendingAlerts = 48
    private static let refreshInterval: Duration = .seconds(12 * 3600)
    private static let debounceInterval: Duration = .seconds(2)

    private var modelContainer: ModelContainer?
    private var notificationService: AppNotificationService = .shared
    private var storeObserver: (any NSObjectProtocol)?
    private var refreshLoop: Task<Void, Never>?
    private var pendingReconcile: Task<Void, Never>?

    /// Injectable clock so tests pin "now".
    var now: () -> Date = { .now }

    /// Injectable settings gate. When alerts are off, reconciliation books
    /// nothing *and clears what's already booked* — `canPost` alone only
    /// stops new requests, leaving previously scheduled ones to fire.
    var alertsEnabledProvider: () -> Bool = {
        SettingsStorage.areCalendarAlertNotificationsEnabled()
    }

    private init() {}

    #if DEBUG
    /// Isolated instances for tests (suites run in parallel; the shared
    /// singleton would race).
    init(notificationService: AppNotificationService) {
        self.notificationService = notificationService
    }
    #endif

    func start(modelContainer: ModelContainer) {
        guard storeObserver == nil else { return }
        self.modelContainer = modelContainer

        storeObserver = NotificationCenter.default.addObserver(
            forName: .calendarStoreDidChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                CalendarAlertScheduler.shared.scheduleReconcile()
            }
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        storeObserver = nil
        refreshLoop?.cancel()
        refreshLoop = nil
        pendingReconcile?.cancel()
        pendingReconcile = nil
        modelContainer = nil
    }

    /// Called when a notification toggle changes so a disable clears already
    /// booked alerts promptly (not just on the next store change / refresh
    /// tick).
    func settingsDidChange() {
        guard modelContainer != nil else { return }
        scheduleReconcile()
    }

    /// Removes every booked calendar alert. For when the Calendar feature is
    /// switched off entirely — the scheduler stops observing, so reconcile
    /// would never run again to clean these up.
    func clearAllPendingAlerts() {
        let service = notificationService
        Task { @MainActor in
            let booked = await service.pendingCalendarAlertIdentifiers()
            service.removePendingCalendarAlerts(identifiers: Array(booked))
        }
    }

    private func scheduleReconcile() {
        pendingReconcile?.cancel()
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// One reconciliation pass. Internal (not private) + container-injectable
    /// so tests drive it directly.
    func reconcile(modelContainer overrideContainer: ModelContainer? = nil) async {
        guard let container = overrideContainer ?? modelContainer else { return }
        let currentDate = now()
        // Booked by fire date; occurrences are expanded further out so an
        // alarm with a long lead ("1 week before" an event 10 days away)
        // isn't missed just because its event sits past the horizon.
        let fireWindow = DateInterval(start: currentDate, duration: Self.horizon)
        let occurrenceWindow = DateInterval(
            start: currentDate,
            duration: Self.horizon + Self.maximumAlarmLeadTime
        )
        let repository = CalendarRepository(modelContext: ModelContext(container))

        // Desired alarms: per occurrence per alarm offset, future-only,
        // soonest-first under the budget. Empty when the user has alerts
        // switched off, so the subtraction below clears everything booked.
        struct DesiredAlert {
            let identifier: String
            let eventID: UUID
            let title: String
            let occurrenceStart: Date
            let fireDate: Date
            let isAllDay: Bool
        }
        var desired: [DesiredAlert] = []
        let eventsByID = alertsEnabledProvider()
            ? Dictionary(
                grouping: repository.occurrences(in: occurrenceWindow, visibleCalendarsOnly: false),
                by: \.eventID
            )
            : [:]
        for (eventID, occurrences) in eventsByID {
            guard let event = repository.event(withID: eventID) else { continue }
            let alarms = event.alarms
            guard !alarms.isEmpty else { continue }
            for occurrence in occurrences {
                for alarm in alarms {
                    let fireDate = occurrence.start.addingTimeInterval(alarm.offsetSeconds)
                    guard fireDate > currentDate, fireDate <= fireWindow.end else { continue }
                    desired.append(DesiredAlert(
                        identifier: NotificationIdentifier.calendarAlert(eventID: eventID, fireDate: fireDate),
                        eventID: eventID,
                        title: occurrence.title,
                        occurrenceStart: occurrence.start,
                        fireDate: fireDate,
                        isAllDay: occurrence.isAllDay
                    ))
                }
            }
        }
        desired.sort { $0.fireDate < $1.fireDate }
        if desired.count > Self.maximumPendingAlerts {
            desired.removeLast(desired.count - Self.maximumPendingAlerts)
        }

        let booked = await notificationService.pendingCalendarAlertIdentifiers()
        let desiredIdentifiers = Set(desired.map(\.identifier))

        let stale = booked.subtracting(desiredIdentifiers)
        notificationService.removePendingCalendarAlerts(identifiers: Array(stale))

        var added = 0
        for alert in desired where !booked.contains(alert.identifier) {
            notificationService.scheduleEventAlert(
                identifier: alert.identifier,
                eventID: alert.eventID,
                title: alert.title,
                occurrenceStart: alert.occurrenceStart,
                fireDate: alert.fireDate,
                isAllDay: alert.isAllDay
            )
            added += 1
        }
        if added > 0 || !stale.isEmpty {
            Self.logger.info("""
                alert reconcile: +\(added, privacy: .public) −\(stale.count, privacy: .public) \
                (\(desired.count, privacy: .public) booked in window)
                """)
        }
    }

    #if DEBUG
    func resetForTesting() {
        stop()
    }
    #endif
}
