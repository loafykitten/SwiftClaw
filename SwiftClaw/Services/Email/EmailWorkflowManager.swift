import Foundation
import SwiftData
import Observation
import os
#if os(macOS)
import AppKit
#endif

/// Owns the mail-sync scheduler and review-service lifecycle. Started in
/// `SwiftClawApp.init` only when `SettingsStorage.isEmailEnabled()` is true.
/// Stopped when the user toggles Email off.
@MainActor
@Observable
final class EmailWorkflowManager {
    private static let logger = AppLog.make("mail.workflow")

    static let shared = EmailWorkflowManager()

    private var schedulers: [MailSyncScheduler] = []
    private var reviewTask: Task<Void, Never>?
    private var reviewService: EmailReviewService?
    private var lastReviewRun: Date?
    private var reviewChatOpenedObserver: NSObjectProtocol?

    private init() {}

    func start(modelContainer: ModelContainer) {
        guard SettingsStorage.isEmailEnabled() else {
            return
        }
        guard schedulers.isEmpty else {
            return
        }

        let worker = MailSyncWorker(
            accountsProvider: EmailAccountStore.shared.accountsProvider(),
            modelContainer: modelContainer
        )

        schedulers = MailSyncSchedulerFactory.make(
            worker: worker,
            intervalProvider: {
                SettingsStorage.loadEmailPollInterval()
            }
        )
        schedulers.forEach { $0.start() }

        let reviewService = EmailReviewService(
            modelContainer: modelContainer
        )
        reviewService.onReviewCreated = { [weak self] chatID in
            self?.handleReviewChatCreated(chatID)
        }
        self.reviewService = reviewService

        // Clear the dock badge once the user actually opens the review chat
        // (otherwise the badge lingers forever after a review lands).
        reviewChatOpenedObserver = NotificationCenter.default.addObserver(
            forName: .emailReviewChatOpened,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.clearDockBadge() }
        }

        startReviewLoop(modelContainer: modelContainer)
        Self.logger.info("email workflow started")
    }

    func stop() {
        schedulers.forEach { $0.stop() }
        schedulers.removeAll()
        reviewTask?.cancel()
        reviewTask = nil
        reviewService = nil
        if let observer = reviewChatOpenedObserver {
            NotificationCenter.default.removeObserver(observer)
            reviewChatOpenedObserver = nil
        }
        clearDockBadge()
        Self.logger.info("email workflow stopped")
    }

    /// Kicks an immediate sync + review pass.
    func refreshNow() async {
        for scheduler in schedulers {
            await scheduler.refreshNow()
        }
        await runReviewOnce()
    }

    /// Kicks an immediate review pass only (no mail sync). Wired to the
    /// "Review Now" toolbar button in `EmailView`. Exposed for manual
    /// triggering separately from `refreshNow()` (which syncs + reviews) so
    /// the user can re-run triage without paying for a full mail pull.
    ///
    /// Forces past the 60 s overlap guard so a manual tap always runs and the
    /// button feels responsive (previously the manual button could silently
    /// no-op when a scheduled pass had just fired).
    /// Returns the review's final status message (e.g. "Review complete",
    /// "No email to review") so callers like the AI refresh tool can relay it.
    @discardableResult
    func reviewNow(appendingTo chatID: UUID? = nil) async -> String? {
        await runReviewOnce(force: true, targetChatID: chatID)
    }

    /// Outcome of a conversational refresh (the `refresh_email_review` tool).
    /// `summary` is non-nil ONLY when the pass actually surfaced emails and
    /// posted a card — it's the model's own summary, for the assistant to
    /// relay. `status` always describes what happened so the assistant can be
    /// honest when nothing was surfaced (never claim a card appeared when it
    /// didn't).
    struct ConversationalReviewOutcome {
        let summary: String?
        let status: String
    }

    /// Runs a refresh triggered from inside the review chat. The inline summary
    /// is suppressed so the chat assistant delivers the single closing reply.
    func conversationalReview(appendingTo chatID: UUID) async -> ConversationalReviewOutcome {
        let status = await runReviewOnce(force: true, targetChatID: chatID, conversational: true)
            ?? "Review did not run"
        return ConversationalReviewOutcome(
            summary: reviewService?.lastSummaryMessage,
            status: status
        )
    }

    private func startReviewLoop(modelContainer: ModelContainer) {
        reviewTask = Task { [weak self] in
            guard let self else { return }
            // Don't fire an inference call the instant the app enables
            // email — let the first mail sync land first so the review has
            // something to look at. The scheduler's first tick will run
            // shortly; review then proceeds on its own cadence.
            let initialDelay = max(60, SettingsStorage.loadEmailReviewInterval() / 4)
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                await self.runReviewOnce()
                let interval = max(300, SettingsStorage.loadEmailReviewInterval())
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// `force` bypasses the 60 s overlap guard (used by the manual "Review
    /// Now" button so it always runs even if the scheduled loop just fired).
    /// The scheduled loop passes `force: false` so back-to-back scheduled
    /// ticks don't pile up inference calls.
    ///
    /// The "no model configured" guard lives in `EmailReviewService.runOnce()`
    /// (the canonical place — it surfaces the status + returns `false`).
    /// Mirroring it here meant the production path double-checked; we
    /// instead rely on `runOnce()`'s return value to set the manual-path
    /// "Review complete" status only when the pass actually ran.
    @discardableResult
    private func runReviewOnce(
        force: Bool = false,
        targetChatID: UUID? = nil,
        conversational: Bool = false
    ) async -> String? {
        guard let reviewService else { return nil }
        // Guard against overlapping runs (scheduled path only). The manual
        // button forces past this so the user gets immediate feedback.
        if !force {
            guard lastReviewRun == nil
                || Date().timeIntervalSince(lastReviewRun!) > 60 else {
                return nil
            }
        }
        // Surface an active status for the manual path so the button gives
        // immediate feedback that something is happening (the scheduled path
        // stays quiet to avoid spamming the status line every interval).
        if force {
            MailSyncMonitor.shared.setReviewing(true)
        }
        guard !ProcessInfo.processInfo.isRunningInPreview else { return nil }
        lastReviewRun = .now
        let didRun = await reviewService.runOnce(
            force: force,
            targetChatID: targetChatID,
            suppressInlineSummary: conversational
        )
        let status = reviewService.lastStatusMessage
            ?? (didRun ? "Review complete" : "Review did not run")
        if force {
            MailSyncMonitor.shared.setStatus(status, syncing: false)
            MailSyncMonitor.shared.isReviewing = false
        }
        return status
    }

    private func handleReviewChatCreated(_ chatID: UUID) {
        let autoNavigate = UserDefaults.standard.object(
            forKey: SettingsKeys.emailAutoNavigateToReviewChat
        ) as? Bool ?? SettingsStorage.defaultEmailAutoNavigateToReviewChat

        NotificationCenter.default.post(
            name: .emailReviewChatCreated,
            object: nil,
            userInfo: ["chatID": chatID, "autoNavigate": autoNavigate]
        )

        if !autoNavigate {
            dockBadge()
        }
    }

    private func dockBadge() {
        #if os(macOS)
        Task { @MainActor in
            let count = Int(NSApp.dockTile.badgeLabel ?? "0") ?? 0
            NSApp.dockTile.badgeLabel = "\(count + 1)"
        }
        #endif
    }

    private func clearDockBadge() {
        #if os(macOS)
        Task { @MainActor in
            NSApp.dockTile.badgeLabel = nil
        }
        #endif
    }
}

extension Notification.Name {
    static let emailReviewChatCreated = Notification.Name("email.review.chatCreated")
    /// Posted when the user opens the review chat — `EmailWorkflowManager`
    /// listens to clear the macOS dock badge so the badge doesn't linger
    /// indefinitely after the user has acknowledged the review.
    static let emailReviewChatOpened = Notification.Name("email.review.chatOpened")
    /// Posted when the user taps a review-card email row to view it in
    /// EmailView. `userInfo: ["emailID": UUID]` — the `Email.id` to select.
    static let emailReviewViewEmail = Notification.Name("email.review.viewEmail")
}
