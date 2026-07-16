import Foundation
import Observation
import os
import SwiftData

@MainActor
@Observable
final class NotesWorkflowManager {
    private static let logger = AppLog.make("notes.workflow")
    static let shared = NotesWorkflowManager()
    private var reviewTask: Task<Void, Never>?
    private var reviewService: NotesReviewService?
    private var lastReviewRun: Date?
    private var isReviewRunning = false
    private var scheduleObserver: (any NSObjectProtocol)?
    private var userDefaults: UserDefaults = .standard
    private typealias ReviewRunHandler = @MainActor (NotesReviewService, Bool, UUID?) async -> Bool
    private var reviewRunHandler: ReviewRunHandler?
    private init() {}

    #if DEBUG
        func configureForTesting(userDefaults: UserDefaults, reviewRunHandler: (@MainActor (NotesReviewService, Bool, UUID?) async -> Bool)? = nil) {
            self.userDefaults = userDefaults; self.reviewRunHandler = reviewRunHandler
        }

        func resetForTesting() {
            stop(); userDefaults = .standard; reviewRunHandler = nil; lastReviewRun = nil
        }
    #endif

    func start(modelContainer: ModelContainer) {
        guard SettingsStorage.isNotesEnabled(userDefaults: userDefaults), reviewService == nil else { return }
        let service = NotesReviewService(modelContainer: modelContainer, userDefaults: userDefaults)
        service.onReviewCreated = { [weak self] id, summary in self?.handleReviewChatCreated(chatID: id, summary: summary) }
        reviewService = service
        scheduleObserver = NotificationCenter.default.addObserver(forName: SettingsNotifications.notesReviewScheduleDidChange, object: nil, queue: nil) { _ in
            Task { @MainActor in NotesWorkflowManager.shared.restartReviewLoop() }
        }
        startReviewLoop()
    }

    func stop() {
        reviewTask?.cancel(); reviewTask = nil; reviewService = nil; lastReviewRun = nil; isReviewRunning = false
        if let scheduleObserver {
            NotificationCenter.default.removeObserver(scheduleObserver)
        }
        scheduleObserver = nil
    }

    @discardableResult
    func reviewNow(appendingTo chatID: UUID? = nil) async -> String? {
        await runReviewOnce(force: true, targetChatID: chatID)
    }

    private func startReviewLoop() {
        reviewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = nextReviewDate() else { return }
                let delay = max(0, next.timeIntervalSinceNow)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(Int(delay.rounded(.up))))
                }
                guard !Task.isCancelled else { return }
                _ = await runReviewOnce()
            }
        }
    }

    private func restartReviewLoop() {
        guard reviewService != nil else { return }; reviewTask?.cancel(); reviewTask = nil; startReviewLoop()
    }

    private func nextReviewDate(now: Date = .now) -> Date? {
        let interval = SettingsStorage.loadNotesReviewInterval(userDefaults: userDefaults)
        guard interval > 0 else { return nil }
        let anchor = [SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: userDefaults), lastReviewRun].compactMap(\.self).max()
        return anchor?.addingTimeInterval(TimeInterval(interval)) ?? now
    }

    @discardableResult
    private func runReviewOnce(force: Bool = false, targetChatID: UUID? = nil) async -> String? {
        guard let service = reviewService else { return nil }
        guard !isReviewRunning else { return "Review already in progress" }
        guard !ProcessInfo.processInfo.isRunningInPreview else { return nil }
        if !force, let lastReviewRun, Date.now.timeIntervalSince(lastReviewRun) <= 60 {
            return nil
        }
        isReviewRunning = true; defer { isReviewRunning = false }
        lastReviewRun = .now
        let didRun = if let reviewRunHandler {
            await reviewRunHandler(service, force, targetChatID)
        } else {
            await service.runOnce(force: force, targetChatID: targetChatID)
        }
        if didRun {
            lastReviewRun = SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: userDefaults) ?? .now
        }
        return service.lastStatusMessage ?? (didRun ? "Review complete" : "Review did not run")
    }

    private func handleReviewChatCreated(chatID: UUID, summary: String) {
        NotificationCenter.default.post(name: .emailReviewChatCreated, object: nil, userInfo: ["chatID": chatID, "autoNavigate": false])
        AppNotificationService.shared.notifyReviewResult(chatID: chatID, summary: summary, title: "Notes review ready")
    }
}
