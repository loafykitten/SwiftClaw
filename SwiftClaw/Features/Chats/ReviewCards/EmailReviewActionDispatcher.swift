import Foundation
import SwiftData

/// Executes email review actions (resolved via `ReviewActionToken`) against
/// the `EmailRepository` + a per-email `MailClient` resolved from the email's
/// `accountID` via `EmailAccountStore`. Surfaces failures via
/// `MailSyncMonitor`.
@MainActor
final class EmailReviewActionDispatcher: ReviewActionDispatcher {
    let reviewType: ReviewType = .email

    private let modelContainer: ModelContainer
    private let mailClientFactory: @MainActor (UUID) -> MailClient?

    init(
        modelContainer: ModelContainer,
        mailClientFactory: @escaping @MainActor (UUID) -> MailClient? = EmailReviewActionDispatcher.defaultMailClientFactory
    ) {
        self.modelContainer = modelContainer
        self.mailClientFactory = mailClientFactory
    }

    /// Default per-email `MailClient` resolver: looks the account up in
    /// `EmailAccountStore` and constructs a `SwiftMailClient` bound to its
    /// Keychain credentials. Returns `nil` when the account has been removed
    /// or is incomplete (the dispatcher still applies the local mutation in
    /// that case).
    @MainActor
    private static func defaultMailClientFactory(accountID: UUID) -> MailClient? {
        EmailMailClientResolver.mailClient(forAccountID: accountID)
    }

    func perform(action: ReviewActionToken, itemID: UUID) async {
        let context = ModelContext(modelContainer)
        let repository = EmailRepository(modelContext: context)

        guard let email = repository.fetchEmail(by: itemID) else {
            return
        }

        let mailClient = mailClientFactory(email.accountID)

        switch action {
        case .review:
            // Mark read locally AND sync `\Seen` to the server — without the
            // server update the message re-appears as unread on other clients
            // + the next flag reconcile.
            await EmailServerAction.setFlags(
                email: email, repository: repository, mailClient: mailClient,
                isRead: true, isFlagged: nil
            )
        case .flag:
            await EmailServerAction.toggleFlag(
                email: email, repository: repository, mailClient: mailClient
            )
        case .reply:
            // Reply from a review card isn't wired to a composer (would need
            // cross-pane navigation); flag the email as actionable so it
            // surfaces in the Flagged mailbox for the user to reply to from
            // `EmailView`. Documented limitation rather than a silent no-op.
            await EmailServerAction.setFlags(
                email: email, repository: repository, mailClient: mailClient,
                isRead: true, isFlagged: true
            )
        case .archive:
            await EmailServerAction.archive(
                email: email, repository: repository, mailClient: mailClient
            )
        case .delete:
            // Soft-delete — moved to the account's Trash folder (recoverable),
            // not an irreversible server expunge.
            await EmailServerAction.delete(
                email: email, repository: repository, mailClient: mailClient
            )
        }
    }
}
