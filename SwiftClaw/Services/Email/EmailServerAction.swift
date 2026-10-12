import Foundation
import os

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
///
/// Rows without a server identity (`Email.serverUID == nil`: a just-sent
/// echo, a pending move to Trash, a UID invalidated by a UIDVALIDITY reset)
/// get the local mutation only. Their placeholder uid could name an
/// unrelated server message, so nothing is sent until sync re-keys them;
/// pending flag changes are then retried by `MailSyncWorker`.
@MainActor
enum EmailServerAction {
    private static let logger = AppLog.make("mail.action")

    /// Archives the email locally + moves it to the account's resolved
    /// SPECIAL-USE Archive folder on the server. Gmail's archive target is
    /// `[Gmail]/All Mail` (no literal "Archive" folder), which is why the
    /// server call goes through `MailClient.archive(...)` rather than a
    /// hardcoded mailbox name.
    static func archive(email: Email, repository: EmailRepository, mailClient: MailClient?) async {
        let mailbox = email.mailbox
        let uid = email.serverUID
        repository.archive(messageID: email.id)
        guard let mailClient, let uid else { return }
        do {
            try await mailClient.archive(uid: uid, from: mailbox)
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
        let fallbackTrashMailbox = EmailAccountStore.shared
            .account(for: email.accountID)?
            .resolvedTrashMailbox ?? "Trash"
        Self.logger.info("""
            delete requested emailID=\(email.id.uuidString, privacy: .public) \
            uid=\(email.uid, privacy: .public) sourceMailbox=\(sourceMailbox, privacy: .public) \
            fallbackTrash=\(fallbackTrashMailbox, privacy: .public)
            """)
        guard let mailClient, let uid = email.serverUID else {
            // No server move will happen, so the row keeps its real
            // source-folder identity; refiling it under Trash would strand
            // it with a placeholder that no Trash sync ever resolves.
            repository.delete(messageID: email.id)
            return
        }
        repository.delete(messageID: email.id, movedToMailbox: fallbackTrashMailbox)
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
            // The message never left the source folder: give the row its
            // real identity back so later actions (Delete Permanently, flag
            // sync) address the right server message.
            repository.revertPendingMove(messageID: email.id, toMailbox: sourceMailbox, uid: uid)
            Self.logger.error("""
                delete server move failed emailID=\(email.id.uuidString, privacy: .public) \
                uid=\(uid, privacy: .public) sourceMailbox=\(sourceMailbox, privacy: .public): \
                \(String(describing: error))
                """)
            MailSyncMonitor.shared.setStatus(
                "Couldn't move to Trash on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
    }

    /// Irreversibly deletes the email: expunges the server copy (best-effort)
    /// AND hard-deletes the local row + its notes + on-disk attachment bytes.
    /// Only the Trash-mailbox "Delete Permanently" affordance should call this;
    /// the local row already being in Trash implies a prior `delete`, so the
    /// server call here is the expunge on the Trash mailbox.
    ///
    /// Server expunge runs first; if it fails the error surfaces through
    /// `MailSyncMonitor` but the local hard-delete still proceeds — losing
    /// local-only state because the server call failed would be worse than
    /// leaving the server copy to be re-synced. If the account has been removed
    /// (`mailClient == nil`) the server call is skipped and the local
    /// hard-delete still runs.
    static func deletePermanently(email: Email, repository: EmailRepository, mailClient: MailClient?) async {
        if let mailClient, let uid = email.serverUID {
            do {
                try await mailClient.deletePermanently(uid: uid, in: email.mailbox)
            } catch {
                MailSyncMonitor.shared.setStatus(
                    "Couldn't expunge from the server: \(error.localizedDescription)",
                    syncing: false
                )
            }
        }
        repository.deletePermanently(messageID: email.id)
    }

    /// Toggles the flag locally + mirrors the new value to the server. Returns
    /// the new flag state so review-card / detail-view callers can use it
    /// without re-reading the model (matches `EmailRepository.toggleFlag`'s
    /// return shape).
    @discardableResult
    static func toggleFlag(email: Email, repository: EmailRepository, mailClient: MailClient?) async -> Bool? {
        let hadPendingChange = email.needsFlagSync
        guard let newValue = repository.toggleFlag(messageID: email.id) else { return nil }
        guard let mailClient, let uid = email.serverUID else { return newValue }
        let updates = pushUpdate(
            for: email,
            hadPendingChange: hadPendingChange,
            changed: MailFlagUpdate(isRead: nil, isFlagged: newValue)
        )
        do {
            try await mailClient.setFlags(uid: uid, mailbox: email.mailbox, updates: updates)
            repository.clearFlagSyncPending(messageID: email.id, acknowledging: updates)
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
        let hadPendingChange = email.needsFlagSync
        if let isRead { repository.setRead(messageID: email.id, isRead: isRead) }
        if let isFlagged { repository.setFlag(messageID: email.id, isFlagged: isFlagged) }
        guard let mailClient, let uid = email.serverUID else { return }
        let updates = pushUpdate(
            for: email,
            hadPendingChange: hadPendingChange,
            changed: MailFlagUpdate(isRead: isRead, isFlagged: isFlagged)
        )
        do {
            try await mailClient.setFlags(uid: uid, mailbox: email.mailbox, updates: updates)
            repository.clearFlagSyncPending(messageID: email.id, acknowledging: updates)
        } catch {
            MailSyncMonitor.shared.setStatus(
                "Couldn't update flags on the server: \(error.localizedDescription)",
                syncing: false
            )
        }
    }

    /// What to send for a flag/read change. Normally only the component the
    /// user changed, so an unrelated server-side change isn't overwritten.
    /// When an earlier change was still unconfirmed, the pending marker
    /// covers both components, so both local values go out and one ack
    /// settles the whole row.
    private static func pushUpdate(
        for email: Email,
        hadPendingChange: Bool,
        changed: MailFlagUpdate
    ) -> MailFlagUpdate {
        guard hadPendingChange else { return changed }
        return MailFlagUpdate(isRead: email.isRead, isFlagged: email.isFlagged)
    }
}
