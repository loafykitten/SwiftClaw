import Foundation
import Observation
import UserNotifications
import os

/// Facade every feature posts local notifications through. Owns the
/// `UNUserNotificationCenter` delegate, category registration, the
/// master/per-source/authorization gating, and the new-mail digest policy.
///
/// The dock badge stays with `AppRouter` — this service never sets `.badge`
/// content and never requests `.badge` authorization.
///
/// NSObject subclass solely for `UNUserNotificationCenterDelegate`.
@MainActor
@Observable
final class AppNotificationService: NSObject {
    static let shared = AppNotificationService()

    private static let logger = AppLog.make("notifications")

    /// Per account per sync pass: up to this many new messages get individual
    /// notifications (with quick actions); more collapse into a single digest.
    /// Tune after live testing.
    static let maxIndividualMailNotifications = 4

    /// Notification bodies are capped so a long assistant answer or review
    /// summary doesn't overflow the banner (the system truncates hard at a
    /// few lines anyway; our cap adds a tidy ellipsis instead).
    static let chatReplyPreviewLimit = 150
    static let reviewSummaryLimit = 150

    /// Last known system authorization status; drives the Settings UI
    /// (denied-state warning + toggle behavior).
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var center: (any NotificationScheduling)?
    @ObservationIgnored private var userDefaults: UserDefaults = .standard
    @ObservationIgnored private var isActivated = false
    /// In-flight `center.add` tasks. Tracked so DEBUG tests can await
    /// deterministic delivery into the spy; pruned on completion.
    @ObservationIgnored private var postTasks: [UUID: Task<Void, Never>] = [:]
    /// Injectable Reminders feature gate for the `.reminder` tap route
    /// (routing tests run against `.shared`, whose defaults are `.standard`).
    @ObservationIgnored var isRemindersFeatureEnabled: () -> Bool = {
        SettingsStorage.isRemindersEnabled()
    }

    /// Use `shared` in app code. The initializer is internal (not private)
    /// so tests can build isolated instances — suites run in parallel, and
    /// two suites configuring the shared singleton race each other (one
    /// suite's `configureForTesting` cancels the other's in-flight posts).
    override init() {
        super.init()
    }

    #if DEBUG
    /// Mirrors `EmailWorkflowManager.configureForTesting`: injects a spy
    /// center + isolated defaults so tests never touch the real notification
    /// center or `.standard`. Also clears the activation latch — the test
    /// bundle is injected into the real app (`TEST_HOST`), whose launch
    /// already ran `activate()` against the system center — so each test
    /// starts from a deterministic not-activated state. Call `activate()`
    /// afterwards to exercise delegate/category installation.
    func configureForTesting(center: any NotificationScheduling, userDefaults: UserDefaults) {
        postTasks.values.forEach { $0.cancel() }
        postTasks.removeAll()
        isActivated = false
        authorizationStatus = .notDetermined
        self.center = center
        self.userDefaults = userDefaults
    }

    func resetForTesting() {
        postTasks.values.forEach { $0.cancel() }
        postTasks.removeAll()
        center = nil
        userDefaults = .standard
        isActivated = false
        authorizationStatus = .notDetermined
    }

    /// Awaits all in-flight `center.add` tasks so tests can assert against
    /// the spy without racing the posting `Task`s.
    func flushPostsForTesting() async {
        for task in postTasks.values {
            await task.value
        }
    }
    #endif

    /// Installs the delegate + notification categories. Called from
    /// `SwiftClawApp.init` (preview-guarded) so a notification tap that
    /// launches the app is caught before launch completes.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        let center = self.center ?? SystemNotificationCenter()
        self.center = center
        center.setDelegate(self)
        center.setNotificationCategories([Self.newMailCategory])
        Task { await refreshAuthorizationStatus() }
    }

    /// The Settings master-toggle "on" path: requests authorization when the
    /// system still shows `.notDetermined`. Alert + sound only — never
    /// `.badge` (the dock badge belongs to `AppRouter`'s unread-chat count).
    /// Returns whether notifications are authorized after the request.
    @discardableResult
    func enableNotifications() async -> Bool {
        guard isActivated, let center else { return false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.error("authorization request failed: \(String(describing: error))")
        }
        await refreshAuthorizationStatus()
        return authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    func refreshAuthorizationStatus() async {
        guard let center else { return }
        authorizationStatus = await center.authorizationStatus()
    }

    // MARK: - One-time launch offer

    /// Whether the app should show its one-time launch alert offering to
    /// enable notifications. True only while the system status is still
    /// `.notDetermined` (nothing has ever prompted) and the offer hasn't been
    /// answered before. The offer is an in-app alert, NOT the system dialog:
    /// declining it leaves the system status untouched, so the Settings
    /// toggle can still raise the real authorization prompt later.
    func shouldOfferLaunchPrompt() async -> Bool {
        guard isActivated, center != nil else { return false }
        guard !SettingsStorage.hasCompletedNotificationsLaunchPrompt(userDefaults: userDefaults) else {
            return false
        }
        await refreshAuthorizationStatus()
        return authorizationStatus == .notDetermined
    }

    /// The launch offer's "Enable" path: flips the master setting on (so
    /// Settings reflects the choice) and runs the real authorization request.
    func acceptLaunchPrompt() async {
        SettingsStorage.markNotificationsLaunchPromptCompleted(userDefaults: userDefaults)
        userDefaults.set(true, forKey: SettingsKeys.notificationsEnabled)
        await enableNotifications()
    }

    /// The launch offer's "Not Now" path: just remembers the answer. The
    /// system status stays `.notDetermined`, so enabling from Settings later
    /// still shows the authorization dialog.
    func declineLaunchPrompt() {
        SettingsStorage.markNotificationsLaunchPromptCompleted(userDefaults: userDefaults)
    }

    // MARK: - Posting API

    func notifyChatReply(chatID: UUID, chatTitle: String, preview: String) {
        guard canPost(source: .chatReplies) else { return }
        let content = UNMutableNotificationContent()
        content.title = chatTitle
        content.body = Self.truncatedBody(preview, limit: Self.chatReplyPreviewLimit)
        content.sound = .default
        content.threadIdentifier = "chat.\(chatID.uuidString)"
        content.userInfo = NotificationRoutingPayload(kind: .chatReply, targetID: chatID).userInfo
        post(content: content, identifier: NotificationIdentifier.chatReply(chatID), source: .chatReplies)
    }

    func notifyReviewResult(chatID: UUID, summary: String, title: String = "Inbox review ready") {
        guard canPost(source: .reviewResults) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        // The summary is usually the model's dedicated `notification_summary`
        // one-liner; the cap is the safety net for the full-message fallback.
        content.body = Self.truncatedBody(summary, limit: Self.reviewSummaryLimit)
        content.sound = .default
        content.threadIdentifier = "chat.\(chatID.uuidString)"
        content.userInfo = NotificationRoutingPayload(kind: .review, targetID: chatID).userInfo
        post(content: content, identifier: NotificationIdentifier.review(chatID), source: .reviewResults)
    }

    /// New-mail entry point; owns the digest policy. Per account per sync
    /// pass: 1–`maxIndividualMailNotifications` messages get individual
    /// notifications with quick actions; more collapse into one digest
    /// ("N new messages") that replaces the account's prior digest and
    /// carries no actions.
    func notifyNewMail(_ messages: [NewMailNotificationInfo]) {
        guard canPost(source: .newMail), !messages.isEmpty else { return }

        let byAccount = Dictionary(grouping: messages, by: \.accountID)
        for (accountID, accountMessages) in byAccount {
            if accountMessages.count > Self.maxIndividualMailNotifications {
                let content = UNMutableNotificationContent()
                content.title = "New mail"
                content.body = "\(accountMessages.count) new messages"
                content.sound = .default
                content.threadIdentifier = "mail.\(accountID.uuidString)"
                content.userInfo = NotificationRoutingPayload(
                    kind: .mailDigest,
                    targetID: accountID
                ).userInfo
                post(content: content, identifier: NotificationIdentifier.mailDigest(accountID), source: .newMail)
            } else {
                for message in accountMessages {
                    let content = UNMutableNotificationContent()
                    content.title = message.fromDisplay
                    content.subtitle = message.subject
                    content.body = message.snippet
                    content.sound = .default
                    content.categoryIdentifier = NotificationCategoryID.newMail
                    content.threadIdentifier = "mail.\(accountID.uuidString)"
                    content.userInfo = NotificationRoutingPayload(
                        kind: .newMail,
                        targetID: message.emailID
                    ).userInfo
                    post(content: content, identifier: NotificationIdentifier.mail(message.emailID), source: .newMail)
                }
            }
        }
    }

    /// Posts the Phase-4 inline-reply failure fallback. Routed like a
    /// regular new-mail notification so tapping it reopens the email.
    /// Deliberately posts with no source gate (and therefore no `source:`
    /// re-check): a failed reply must surface even when new-mail
    /// notifications are switched off.
    func notifyReplyFailed(emailID: UUID) {
        guard isActivated else { return }
        let content = UNMutableNotificationContent()
        content.title = "Reply failed"
        content.body = "Reply failed — open SwiftClaw to retry."
        content.sound = .default
        content.userInfo = NotificationRoutingPayload(kind: .newMail, targetID: emailID).userInfo
        post(content: content, identifier: "mail.replyfailed.\(emailID.uuidString)")
    }

    // MARK: - Calendar event alerts (scheduled)

    /// Schedules one event-alert notification for a future fire date via
    /// `UNCalendarNotificationTrigger` — the service's only scheduled (rather
    /// than immediate) posting path. `CalendarAlertScheduler` owns which
    /// alarms exist; this just books one.
    func scheduleEventAlert(
        identifier: String,
        eventID: UUID,
        title: String,
        occurrenceStart: Date,
        fireDate: Date,
        isAllDay: Bool
    ) {
        guard canPost(source: .calendarAlerts), fireDate > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Event" : title
        content.body = isAllDay
            ? occurrenceStart.formatted(.dateTime.weekday(.wide).month().day())
            : occurrenceStart.formatted(date: .abbreviated, time: .shortened)
        content.sound = .default
        content.threadIdentifier = "calendar"
        content.userInfo = NotificationRoutingPayload(kind: .calendarEvent, targetID: eventID).userInfo

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        post(content: content, identifier: identifier, source: .calendarAlerts, trigger: trigger)
    }

    /// Pending (not yet fired) event-alert identifiers, for the scheduler's
    /// reconciliation diff.
    func pendingCalendarAlertIdentifiers() async -> Set<String> {
        guard let center else { return [] }
        let pending = await center.pendingNotificationRequests()
        return Set(
            pending.map(\.identifier)
                .filter { $0.hasPrefix(NotificationIdentifier.calendarAlertPrefix) }
        )
    }

    func removePendingCalendarAlerts(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Reminder due-date alerts (scheduled)

    /// Schedules one reminder due-date notification for a future fire date.
    /// `ReminderAlertScheduler` owns which alerts exist; this just books one.
    /// For date-only reminders the fire date is the user's chosen morning
    /// time, so the body shows just the day.
    func scheduleReminderAlert(
        identifier: String,
        reminderID: UUID,
        title: String,
        dueDate: Date,
        fireDate: Date,
        hasDueTime: Bool
    ) {
        guard canPost(source: .reminderAlerts), fireDate > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Reminder" : title
        content.body = hasDueTime
            ? "Due \(dueDate.formatted(date: .abbreviated, time: .shortened))"
            : "Due \(dueDate.formatted(.dateTime.weekday(.wide).month().day()))"
        content.sound = .default
        content.threadIdentifier = "reminders"
        content.userInfo = NotificationRoutingPayload(kind: .reminder, targetID: reminderID).userInfo

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        post(content: content, identifier: identifier, source: .reminderAlerts, trigger: trigger)
    }

    /// Pending (not yet fired) reminder-alert identifiers, for the scheduler's
    /// reconciliation diff.
    func pendingReminderAlertIdentifiers() async -> Set<String> {
        guard let center else { return [] }
        let pending = await center.pendingNotificationRequests()
        return Set(
            pending.map(\.identifier)
                .filter { $0.hasPrefix(NotificationIdentifier.reminderAlertPrefix) }
        )
    }

    func removePendingReminderAlerts(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - Cleanup when the user reads the thing in-app

    func removeDeliveredChatNotifications(chatID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [
            NotificationIdentifier.chatReply(chatID),
            NotificationIdentifier.review(chatID),
        ])
    }

    /// Pass the email's `accountID` to also retire the account's digest
    /// notification — once the user is reading mail in-app, a lingering
    /// "N new messages" banner is stale regardless of which message they
    /// opened first.
    func removeDeliveredEmailNotification(emailID: UUID, accountID: UUID? = nil) {
        var identifiers = [NotificationIdentifier.mail(emailID)]
        if let accountID {
            identifiers.append(NotificationIdentifier.mailDigest(accountID))
        }
        center?.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    // MARK: - Gating

    private enum NotificationSource {
        case newMail
        case reviewResults
        case chatReplies
        case calendarAlerts
        case reminderAlerts
    }

    private var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    /// Synchronous settings gate only. Authorization is re-checked inside
    /// `post` — the cached `authorizationStatus` can lag right after launch
    /// (`activate()`'s refresh is fire-and-forget), and gating on the stale
    /// cache would silently drop the first sync's notifications for an
    /// already-authorized user.
    private func canPost(source: NotificationSource) -> Bool {
        guard isActivated, center != nil else { return false }
        switch source {
        case .newMail:
            return SettingsStorage.areNewMailNotificationsEnabled(userDefaults: userDefaults)
        case .reviewResults:
            return SettingsStorage.areReviewResultNotificationsEnabled(userDefaults: userDefaults)
        case .chatReplies:
            return SettingsStorage.areChatReplyNotificationsEnabled(userDefaults: userDefaults)
        case .calendarAlerts:
            return SettingsStorage.areCalendarAlertNotificationsEnabled(userDefaults: userDefaults)
        case .reminderAlerts:
            return SettingsStorage.areReminderAlertNotificationsEnabled(userDefaults: userDefaults)
        }
    }

    private static func truncatedBody(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func post(
        content: UNMutableNotificationContent,
        identifier: String,
        source: NotificationSource? = nil,
        trigger: UNNotificationTrigger? = nil
    ) {
        guard let center else { return }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        let taskID = UUID()
        postTasks[taskID] = Task { [weak self] in
            defer { self?.postTasks[taskID] = nil }
            guard let self else { return }
            // Authorization is read fresh at post time (see `canPost`).
            await self.refreshAuthorizationStatus()
            guard self.isAuthorized else { return }
            // Re-check the source gate too: this task suspends above, so a
            // disable can land after the caller's gate but before `add` —
            // without this a scheduled alert books despite the reconcile
            // that just cleared everything (nothing was pending to remove).
            if let source {
                guard self.canPost(source: source) else { return }
            }
            do {
                try await center.add(request)
            } catch {
                Self.logger.error("failed to post notification \(identifier): \(String(describing: error))")
            }
        }
    }

    // MARK: - Categories

    /// Quick actions for individual new-mail notifications. The inline Reply
    /// text action is Phase 4 of docs/plans/notifications.md.
    static var newMailCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: NotificationCategoryID.newMail,
            actions: [
                UNNotificationAction(
                    identifier: NotificationActionID.mailArchive,
                    title: "Archive"
                ),
                UNNotificationAction(
                    identifier: NotificationActionID.mailDelete,
                    title: "Delete",
                    options: [.destructive]
                ),
                UNNotificationAction(
                    identifier: NotificationActionID.mailFlag,
                    title: "Flag"
                ),
                UNTextInputNotificationAction(
                    identifier: NotificationActionID.mailReply,
                    title: "Reply",
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Reply…"
                ),
            ],
            intentIdentifiers: []
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// Swift 6 note: delegate callbacks arrive nonisolated and UN types are not
/// Sendable — every method extracts the identifier/payload/userText it needs
/// BEFORE hopping to the MainActor.
extension AppNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let payload = NotificationRoutingPayload(
            userInfo: notification.request.content.userInfo
        )
        Task { @MainActor in
            let suppress = Self.shouldSuppressPresentation(payload: payload, router: AppRouter.shared)
            completionHandler(suppress ? [] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let payload = NotificationRoutingPayload(
            userInfo: response.notification.request.content.userInfo
        )
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            self.handleResponse(actionIdentifier: actionIdentifier, payload: payload, userText: userText)
            completionHandler()
        }
    }

    /// Show banners even when the app is frontmost, EXCEPT when the user is
    /// already looking at the target: that chat for chat/review kinds, or
    /// (coarse v1 — the router doesn't track the open email) the Workspace
    /// section for mail kinds.
    static func shouldSuppressPresentation(
        payload: NotificationRoutingPayload?,
        router: AppRouter
    ) -> Bool {
        guard let payload else { return false }
        switch payload.kind {
        case .chatReply, .review:
            return router.isViewingChat(payload.targetID)
        case .newMail, .mailDigest:
            return router.selectedNavigationItem == .workspace
        case .calendarEvent, .reminder:
            // Event and reminder alerts are time-critical; show them even in
            // Workspace.
            return false
        }
    }

    private func handleResponse(
        actionIdentifier: String,
        payload: NotificationRoutingPayload?,
        userText: String?
    ) {
        switch actionIdentifier {
        case NotificationActionID.mailArchive,
             NotificationActionID.mailDelete,
             NotificationActionID.mailFlag,
             NotificationActionID.mailReply:
            guard let payload, payload.kind == .newMail else { return }
            NotificationMailActionHandler.shared.handle(
                actionIdentifier: actionIdentifier,
                emailID: payload.targetID,
                userText: userText
            )
        case UNNotificationDefaultActionIdentifier:
            routeNotificationTap(payload: payload)
        default:
            break
        }
    }

    /// Tap navigation. Router-only mutations, so this is safe on a cold
    /// launch before the model container / bootstrap finish. Internal so
    /// routing tests can drive it without a `UNNotificationResponse`.
    func routeNotificationTap(payload: NotificationRoutingPayload?) {
        guard let payload else { return }
        switch payload.kind {
        case .chatReply, .review:
            AppRouter.shared.selectChat(payload.targetID)
        case .newMail:
            AppRouter.shared.showEmail(payload.targetID)
        case .mailDigest:
            AppRouter.shared.selectedNavigationItem = .workspace
        case .calendarEvent:
            AppRouter.shared.showCalendar()
        case .reminder:
            // A delivered alert can outlive the feature being switched off;
            // routing anyway would set a focus ID nothing ever presents
            // RemindersView to clear.
            guard isRemindersFeatureEnabled() else { return }
            AppRouter.shared.showReminders(focusing: payload.targetID)
        }
    }
}
