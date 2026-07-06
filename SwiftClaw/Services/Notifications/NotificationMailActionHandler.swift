import Foundation
import SwiftData
import os

/// Executes the quick actions on new-mail notifications (Archive / Delete /
/// Flag / inline Reply). Reuses `EmailServerAction` verbatim, so the
/// local-mutation + best-effort-server contract matches the review card and
/// thread-detail toolbars.
///
/// A response can arrive before the app has a model container — a quick
/// action tapped on a cold launch reaches the delegate before
/// `AppBootstrap.run()` finishes. Those responses queue here and drain when
/// `configure(modelContainer:)` lands.
@MainActor
final class NotificationMailActionHandler {
    static let shared = NotificationMailActionHandler()

    private static let logger = AppLog.make("notifications.mailaction")

    private struct PendingAction {
        let actionIdentifier: String
        let emailID: UUID
        let userText: String?
    }

    private var modelContainer: ModelContainer?
    private var pendingActions: [PendingAction] = []
    /// In-flight dispatch tasks; pruned on completion. Tracked so DEBUG tests
    /// can await deterministic completion of a `handle(...)` call.
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private var clientFactory: (UUID) -> MailClient? = { accountID in
        EmailMailClientResolver.mailClient(forAccountID: accountID)
    }
    /// Reply seam so tests don't build a real SMTP send. Defaults to
    /// `EmailReplySender.sendQuickReply`.
    private var replySender: (Email, String, ModelContext) async throws -> Void = { email, text, context in
        try await EmailReplySender.sendQuickReply(to: email, bodyText: text, modelContext: context)
    }

    private init() {}

    #if DEBUG
    /// Injects the client/reply seams only. Tests hand over the container via
    /// the production `configure(modelContainer:)` so the pending-queue drain
    /// path is exercised as shipped.
    func configureForTesting(
        clientFactory: @escaping (UUID) -> MailClient?,
        replySender: ((Email, String, ModelContext) async throws -> Void)? = nil
    ) {
        self.clientFactory = clientFactory
        if let replySender {
            self.replySender = replySender
        }
    }

    func resetForTesting() {
        actionTasks.values.forEach { $0.cancel() }
        actionTasks.removeAll()
        modelContainer = nil
        pendingActions.removeAll()
        clientFactory = { accountID in
            EmailMailClientResolver.mailClient(forAccountID: accountID)
        }
        replySender = { email, text, context in
            try await EmailReplySender.sendQuickReply(to: email, bodyText: text, modelContext: context)
        }
    }

    /// Awaits all in-flight dispatch tasks so tests can assert their effects.
    func flushActionsForTesting() async {
        for task in actionTasks.values {
            await task.value
        }
    }
    #endif

    /// Called from `AppBootstrap.run()` once the model container exists.
    /// Drains any actions that arrived before configuration.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let queued = pendingActions
        pendingActions.removeAll()
        for action in queued {
            dispatch(action)
        }
    }

    /// Entry point from the notification delegate. Queues until configured.
    func handle(actionIdentifier: String, emailID: UUID, userText: String?) {
        let action = PendingAction(
            actionIdentifier: actionIdentifier,
            emailID: emailID,
            userText: userText
        )
        guard modelContainer != nil else {
            pendingActions.append(action)
            return
        }
        dispatch(action)
    }

    private func dispatch(_ action: PendingAction) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        let repository = EmailRepository(modelContext: context)
        guard let email = repository.fetchEmail(by: action.emailID) else {
            Self.logger.info("""
                notification action \(action.actionIdentifier, privacy: .public) ignored — \
                email \(action.emailID.uuidString, privacy: .public) no longer exists
                """)
            return
        }
        let mailClient = clientFactory(email.accountID)

        let taskID = UUID()
        actionTasks[taskID] = Task { @MainActor [weak self] in
            defer { self?.actionTasks[taskID] = nil }
            switch action.actionIdentifier {
            case NotificationActionID.mailArchive:
                await EmailServerAction.archive(email: email, repository: repository, mailClient: mailClient)
            case NotificationActionID.mailDelete:
                await EmailServerAction.delete(email: email, repository: repository, mailClient: mailClient)
            case NotificationActionID.mailFlag:
                await EmailServerAction.setFlags(
                    email: email,
                    repository: repository,
                    mailClient: mailClient,
                    isRead: nil,
                    isFlagged: true
                )
            case NotificationActionID.mailReply:
                await self?.reply(to: email, userText: action.userText, context: context)
            default:
                Self.logger.warning("""
                    unknown notification action \(action.actionIdentifier, privacy: .public)
                    """)
            }
        }
    }

    private func reply(to email: Email, userText: String?, context: ModelContext) async {
        guard let userText, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            try await replySender(email, userText, context)
        } catch {
            Self.logger.error("""
                inline reply failed for \(email.id.uuidString, privacy: .public): \
                \(String(describing: error))
                """)
            AppNotificationService.shared.notifyReplyFailed(emailID: email.id)
        }
    }
}
