import Foundation
import Observation
import SwiftData
import os

/// Owns the calendar review loop lifecycle (the `EmailWorkflowManager`
/// pattern, minus sync workers — the calendar has no server to poll; the
/// alert scheduler and sync coordinator run separately). Started from
/// `AppBootstrap.run()` / `ContentView.onChange(of: isCalendarEnabled)`.
@MainActor
@Observable
final class CalendarWorkflowManager {
    private static let logger = AppLog.make("calendar.workflow")

    static let shared = CalendarWorkflowManager()

    private var reviewTask: Task<Void, Never>?
    private var reviewService: CalendarReviewService?
    private var lastReviewRun: Date?
    /// Mutual exclusion across scheduled + manual passes — see
    /// `EmailWorkflowManager.isReviewRunning`.
    private var isReviewRunning = false
    private var scheduleObserver: (any NSObjectProtocol)?
    private var userDefaults: UserDefaults = .standard
    private typealias ReviewRunHandler = @MainActor (CalendarReviewService, Bool, UUID?) async -> Bool
    private var reviewRunHandler: ReviewRunHandler?

    private init() {}

    #if DEBUG
    func configureForTesting(
        userDefaults: UserDefaults,
        reviewRunHandler: (@MainActor (CalendarReviewService, Bool, UUID?) async -> Bool)? = nil
    ) {
        self.userDefaults = userDefaults
        self.reviewRunHandler = reviewRunHandler
    }

    func resetForTesting() {
        stop()
        userDefaults = .standard
        reviewRunHandler = nil
        lastReviewRun = nil
    }
    #endif

    func start(modelContainer: ModelContainer) {
        guard SettingsStorage.isCalendarEnabled(userDefaults: userDefaults) else { return }
        guard reviewService == nil else { return }

        let service = CalendarReviewService(modelContainer: modelContainer, userDefaults: userDefaults)
        service.onReviewCreated = { [weak self] chatID, summary in
            self?.handleReviewChatCreated(chatID: chatID, summary: summary)
        }
        reviewService = service

        scheduleObserver = NotificationCenter.default.addObserver(
            forName: SettingsNotifications.calendarReviewScheduleDidChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                CalendarWorkflowManager.shared.restartReviewLoop()
            }
        }

        startReviewLoop()
        Self.logger.info("calendar workflow started")
    }

    func stop() {
        reviewTask?.cancel()
        reviewTask = nil
        reviewService = nil
        lastReviewRun = nil
        if let scheduleObserver {
            NotificationCenter.default.removeObserver(scheduleObserver)
        }
        scheduleObserver = nil
        Self.logger.info("calendar workflow stopped")
    }

    /// Manual "Review Now": forces past the schedule + throttle guards.
    /// Returns the pass's final status message for the caller to relay.
    @discardableResult
    func reviewNow(appendingTo chatID: UUID? = nil) async -> String? {
        await runReviewOnce(force: true, targetChatID: chatID)
    }

    private func startReviewLoop() {
        reviewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = self.nextReviewDate() else {
                    // Manual-only mode (interval 0): park until the schedule
                    // notification restarts the loop.
                    return
                }
                let delay = max(0, next.timeIntervalSinceNow)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(Int(delay.rounded(.up))))
                }
                guard !Task.isCancelled else { break }
                await self.runReviewOnce()
            }
        }
    }

    private func restartReviewLoop() {
        guard reviewService != nil else { return }
        reviewTask?.cancel()
        reviewTask = nil
        startReviewLoop()
        Self.logger.info("calendar review loop restarted after schedule change")
    }

    /// Next scheduled pass, or nil when scheduled reviews are off.
    private func nextReviewDate(now: Date = .now) -> Date? {
        let interval = SettingsStorage.loadCalendarReviewInterval(userDefaults: userDefaults)
        guard interval > 0 else { return nil }
        let anchor = [
            SettingsStorage.loadCalendarLastReviewCompletedAt(userDefaults: userDefaults),
            lastReviewRun,
        ].compactMap(\.self).max()
        guard let anchor else { return now }
        return anchor.addingTimeInterval(TimeInterval(interval))
    }

    @discardableResult
    private func runReviewOnce(force: Bool = false, targetChatID: UUID? = nil) async -> String? {
        guard let reviewService else { return nil }
        guard !isReviewRunning else {
            Self.logger.info("calendar review skipped — another pass is already running")
            return "Review already in progress"
        }
        isReviewRunning = true
        defer { isReviewRunning = false }
        if !force {
            guard lastReviewRun == nil || Date.now.timeIntervalSince(lastReviewRun!) > 60 else {
                return nil
            }
        }
        guard !ProcessInfo.processInfo.isRunningInPreview else { return nil }

        lastReviewRun = .now
        let didRun: Bool
        if let reviewRunHandler {
            didRun = await reviewRunHandler(reviewService, force, targetChatID)
        } else {
            didRun = await reviewService.runOnce(force: force, targetChatID: targetChatID)
        }
        if didRun {
            let completedAt = Date.now
            SettingsStorage.saveCalendarLastReviewCompletedAt(completedAt, userDefaults: userDefaults)
            lastReviewRun = completedAt
        }
        return reviewService.lastStatusMessage ?? (didRun ? "Review complete" : "Review did not run")
    }

    private func handleReviewChatCreated(chatID: UUID, summary: String) {
        NotificationCenter.default.post(
            name: .emailReviewChatCreated, // shared "review chat created" routing signal
            object: nil,
            userInfo: ["chatID": chatID, "autoNavigate": false]
        )
        AppNotificationService.shared.notifyReviewResult(
            chatID: chatID,
            summary: summary,
            title: "Calendar review ready"
        )
    }
}
