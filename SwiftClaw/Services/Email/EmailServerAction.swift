import Foundation

/// Shared local-mutation + best-effort-server-call helpers for the common
/// per-email actions (archive, delete-to-Trash, flag/read sync). Both call
/// sites that need this shape — `EmailReviewActionDispatcher.perform` and
/// `EmailThreadDetailView`'s toolbar actions — route through these so the
/// local-vs-server divergence wording + `MailSyncMonitor` error surface lives
/// in one place.
///
/// Contract: the local mutation ALWAYS applies (via `EmailRepository`); the
/// server call is best-effort. If the account has been removed
/// (`mailClient == nil`) the local row still reflects the action — it just
/// won't sync until the account is re-added. Server failures surface through
/// `MailSyncMonitor.shared` rather than throwing, so the UI stays responsive
/// (the row flip + removal-from-card already happened locally).
@MainActor
enum EmailServerAction {
    /// Archives the email locally + moves it to the account's resolved
    /// SPECIAL-USE Archive folder on the server. Gmail's archive target is
    /// `[Gmail]/All Mail` (no literal "Archive" folder), which is why the
    /// server call goes through `MailClient.archive(...)` rather than a
    /// hardcoded mailbox name.
    static func archive(email: Email, repository: EmailRepository, mailClient: MailClient?) async {
        repository.archive(messageID: email.id)
        guard let mailClient else { return }
        do {
            try await mailClient.archive(uid: email.uid, from: email.mailbox)
        } catch {
            MailSyncMonitor.shared.setStatus(
                "Couldn't archive on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
    }

    /// Soft-deletes locally (recoverable `isDeleted = true`) + moves the server
    /// copy to the account's resolved Trash folder. Not an irreversible
    /// expunge — the Trash-mailbox "Delete Permanently" affordance owns that
    /// path via `MailClient.deletePermanently`.
    static func delete(email: Email, repository: EmailRepository, mailClient: MailClient?) async {
        let sourceMailbox = email.mailbox
        let uid = email.uid
        let fallbackTrashMailbox = EmailAccountStore.shared
            .account(for: email.accountID)?
            .resolvedTrashMailbox ?? "Trash"
        repository.delete(messageID: email.id, movedToMailbox: fallbackTrashMailbox)
        guard let mailClient else { return }
        do {
            try await mailClient.delete(uid: uid, in: sourceMailbox)
            // The server move resolves + caches the account's real Trash
            // folder. If that name differs from the optimistic fallback, repoint
            // the local row so Trash sync promotes it (matched by Message-ID,
            // scoped to the mailbox name) instead of inserting a duplicate.
            if let resolvedTrashMailbox = EmailAccountStore.shared
                .account(for: email.accountID)?
                .resolvedTrashMailbox,
               resolvedTrashMailbox != fallbackTrashMailbox {
                repository.delete(messageID: email.id, movedToMailbox: resolvedTrashMailbox)
            }
        } catch {
            MailSyncMonitor.shared.setStatus(
                "Couldn't move to Trash on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
    }

    /// Toggles the flag locally + mirrors the new value to the server. Returns
    /// the new flag state so review-card / detail-view callers can use it
    /// without re-reading the model (matches `EmailRepository.toggleFlag`'s
    /// return shape).
    @discardableResult
    static func toggleFlag(email: Email, repository: EmailRepository, mailClient: MailClient?) async -> Bool? {
        guard let newValue = repository.toggleFlag(messageID: email.id) else { return nil }
        guard let mailClient else { return newValue }
        do {
            try await mailClient.setFlags(
                uid: email.uid,
                mailbox: email.mailbox,
                updates: MailFlagUpdate(isRead: nil, isFlagged: newValue)
            )
            repository.clearFlagSyncPending(messageID: email.id)
        } catch {
            MailSyncMonitor.shared.setStatus(
                "Couldn't update the flag on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
        return newValue
    }

    /// Sets read/flag state to explicit values (not a toggle) locally + syncs
    /// both flags to the server in one `setFlags` round-trip. Either component
    /// may be `nil` to leave it untouched. Used by the dispatcher's `.review`
    /// (read-only) + `.reply` (flag+read) paths and the detail view's
    /// mark-latest-as-read.
    static func setFlags(
        email: Email,
        repository: EmailRepository,
        mailClient: MailClient?,
        isRead: Bool?,
        isFlagged: Bool?
    ) async {
        if let isRead { repository.setRead(messageID: email.id, isRead: isRead) }
        if let isFlagged { repository.setFlag(messageID: email.id, isFlagged: isFlagged) }
        guard let mailClient else { return }
        do {
            try await mailClient.setFlags(
                uid: email.uid,
                mailbox: email.mailbox,
                updates: MailFlagUpdate(isRead: isRead, isFlagged: isFlagged)
            )
            repository.clearFlagSyncPending(messageID: email.id)
        } catch {
            MailSyncMonitor.shared.setStatus(
                "Couldn't update flags on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
    }
}
