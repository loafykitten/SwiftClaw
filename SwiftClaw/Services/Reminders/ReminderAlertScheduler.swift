import CryptoKit
import Foundation
import SwiftData
import os

/// Keeps `UNUserNotificationCenter`'s pending requests in step with the
/// reminders store: one alert per pending due-dated reminder, reconciled
/// against what's already booked (add the missing, remove the stale).
/// Identifiers are deterministic per (reminder, fire date), so reconciliation
/// is idempotent.
///
/// Reminders have no alarm offsets — a timed reminder fires at its due date,
/// a date-only reminder at the user's chosen morning time that day. Recurring
/// masters carry `dueDate` as the next pending occurrence, so each master
/// yields at most one alert; completing it rolls the date (and identifier)
/// forward and the next pass rebooks.
///
/// A rolling window keeps the pending count well under iOS's 64-request cap
/// (shared with `CalendarAlertScheduler`'s 36); soonest alerts win when the
/// cap bites. Re-runs on every reminder-store save and on a periodic refresh
/// tick.
@MainActor
final class ReminderAlertScheduler {
    static let shared = ReminderAlertScheduler()

    private static let logger = AppLog.make("reminders.alerts")

    /// How far ahead alerts are booked (by fire date). Reminders fire at
    /// their due moment, so no lead-time expansion beyond the horizon.
    static let horizon: TimeInterval = 7 * 24 * 3600
    /// Booked-alert budget (iOS caps pending requests at 64 app-wide, shared
    /// with the calendar scheduler's 36 and the immediate notifications).
    static let maximumPendingAlerts = 12
    private static let refreshInterval: Duration = .seconds(12 * 3600)
    private static let debounceInterval: Duration = .seconds(2)

    private var modelContainer: ModelContainer?
    private var notificationService: AppNotificationService = .shared
    private var storeObserver: (any NSObjectProtocol)?
    private var refreshLoop: Task<Void, Never>?
    private var pendingReconcile: Task<Void, Never>?
    /// In-flight `clearAllPendingAlerts` removal. Reconciliation awaits it so
    /// a quick feature disable→enable can't read booked identifiers that the
    /// straggling clear is about to delete (which would skip rebooking them).
    private var pendingClear: Task<Void, Never>?
    /// Bumped by every reconciliation pass. A pass that suspended while a
    /// newer one started stops before touching requests: the newer pass read
    /// fresher settings and store state, and the older one's desired set
    /// (empty, for a disable) would undo what it booked.
    private var reconcileGeneration = 0

    /// Injectable clock so tests pin "now".
    var now: () -> Date = { .now }

    /// Injectable zone: date-only due days resolve to local fire times in it.
    var calendarProvider: () -> Calendar = { .current }

    /// Injectable settings gate. When alerts are off, reconciliation books
    /// nothing *and clears what's already booked* — `canPost` alone only
    /// stops new requests, leaving previously scheduled ones to fire.
    var alertsEnabledProvider: () -> Bool = {
        SettingsStorage.areReminderAlertNotificationsEnabled()
    }

    /// Injectable morning-time setting: minutes after local midnight when
    /// date-only reminders fire.
    var allDayAlertMinutesProvider: () -> Int = {
        SettingsStorage.loadRemindersAllDayAlertMinutes()
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
            forName: .reminderStoreDidChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                ReminderAlertScheduler.shared.scheduleReconcile()
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

    /// Called when a notification toggle or the morning time changes so the
    /// change takes effect promptly (not just on the next store change /
    /// refresh tick).
    func settingsDidChange() {
        guard modelContainer != nil else { return }
        scheduleReconcile()
    }

    /// Removes every booked reminder alert. For when the Reminders feature is
    /// switched off entirely — the scheduler stops observing, so reconcile
    /// would never run again to clean these up.
    func clearAllPendingAlerts() {
        let service = notificationService
        pendingClear = Task { @MainActor in
            // Let posts already past their gate land first, or they'd be
            // added after this read and survive the clear.
            await service.waitForInFlightPosts()
            let booked = await service.pendingReminderAlertIdentifiers()
            service.removePendingReminderAlerts(identifiers: Array(booked))
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
        reconcileGeneration += 1
        let generation = reconcileGeneration
        if let pendingClear {
            await pendingClear.value
            self.pendingClear = nil
        }
        let currentDate = now()
        let fireWindow = DateInterval(start: currentDate, duration: Self.horizon)
        let repository = ReminderRepository(modelContext: ModelContext(container))

        // Desired alerts: one per pending due-dated reminder, future-only,
        // soonest-first under the budget. Empty when the user has alerts
        // switched off, so the subtraction below clears everything booked.
        struct DesiredAlert {
            let identifier: String
            let reminderID: UUID
            let title: String
            let dueDate: Date
            let fireDate: Date
            let hasDueTime: Bool
        }
        var desired: [DesiredAlert] = []
        if alertsEnabledProvider() {
            let allDayMinutes = allDayAlertMinutesProvider()
            let calendar = calendarProvider()
            // Bound materialization at the horizon while retaining undated and
            // overdue candidates; fire-date rules below decide what is booked.
            for reminder in repository.pendingReminders(
                dueBefore: fireWindow.end,
                includeUndated: true,
                calendar: calendar
            ) {
                // Date-only dues are civil days: fire on that day's local
                // morning wherever the device is now.
                guard let dueDate = reminder.localDueDate(calendar: calendar) else { continue }
                let fireDate = Self.fireDate(
                    forDueDate: dueDate,
                    hasDueTime: reminder.hasDueTime,
                    allDayAlertMinutes: allDayMinutes,
                    calendar: calendar
                )
                guard fireDate > currentDate, fireDate <= fireWindow.end else { continue }
                desired.append(DesiredAlert(
                    identifier: NotificationIdentifier.reminderAlert(
                        reminderID: reminder.id,
                        fireDate: fireDate,
                        contentFingerprint: Self.contentFingerprint(
                            title: reminder.title,
                            hasDueTime: reminder.hasDueTime
                        )
                    ),
                    reminderID: reminder.id,
                    title: reminder.title,
                    dueDate: dueDate,
                    fireDate: fireDate,
                    hasDueTime: reminder.hasDueTime
                ))
            }
        }
        desired.sort { $0.fireDate < $1.fireDate }
        if desired.count > Self.maximumPendingAlerts {
            desired.removeLast(desired.count - Self.maximumPendingAlerts)
        }

        // Disabling: a post that passed its gate before the toggle flipped
        // may still be suspended inside `center.add`, invisible to the
        // pending list until it lands — let it land, or this pass finds
        // nothing to remove and the alert survives the disable. (Same
        // synchronous stretch as the read above, so the two agree.)
        if !alertsEnabledProvider() {
            await notificationService.waitForInFlightPosts()
        }
        let booked = await notificationService.pendingReminderAlertIdentifiers()
        guard generation == reconcileGeneration else { return }
        let desiredIdentifiers = Set(desired.map(\.identifier))

        let stale = booked.subtracting(desiredIdentifiers)
        notificationService.removePendingReminderAlerts(identifiers: Array(stale))

        var added = 0
        for alert in desired where !booked.contains(alert.identifier) {
            notificationService.scheduleReminderAlert(
                identifier: alert.identifier,
                reminderID: alert.reminderID,
                title: alert.title,
                dueDate: alert.dueDate,
                fireDate: alert.fireDate,
                hasDueTime: alert.hasDueTime
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

    /// Timed reminders fire at their due moment; date-only reminders (local
    /// start-of-day, floating) fire at the configured wall-clock time on the
    /// due day. Set via calendar components, NOT elapsed seconds after
    /// midnight — on a DST transition day those diverge (9:00 AM would drift
    /// to 10:00/8:00).
    static func fireDate(
        forDueDate dueDate: Date,
        hasDueTime: Bool,
        allDayAlertMinutes: Int,
        calendar: Calendar = .current
    ) -> Date {
        guard !hasDueTime else { return dueDate }
        return calendar.date(
            bySettingHour: allDayAlertMinutes / 60,
            minute: allDayAlertMinutes % 60,
            second: 0,
            of: dueDate
        ) ?? calendar.startOfDay(for: dueDate).addingTimeInterval(TimeInterval(allDayAlertMinutes * 60))
    }

    /// Stable (cross-launch) digest of the user-visible alert content, folded
    /// into the identifier so edits rebook the request. `String.hashValue` is
    /// process-seeded and would rebook everything on every launch.
    private static func contentFingerprint(title: String, hasDueTime: Bool) -> String {
        let digest = SHA256.hash(data: Data("\(title)|\(hasDueTime)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    func resetForTesting() {
        stop()
    }
    #endif
}
