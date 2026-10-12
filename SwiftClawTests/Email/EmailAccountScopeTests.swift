import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct EmailAccountScopeTests {
    @Test func allAccountsIncludesAllThreadPartitions() {
        let accountA = UUID()
        let accountB = UUID()
        let inboxA = Self.email(accountID: accountA, subject: "Inbox A")
        let inboxB = Self.email(accountID: accountB, subject: "Inbox B")
        let archivedB = Self.email(accountID: accountB, subject: "Archive B", isArchived: true)

        let snapshot = EmailThreadScopeSnapshot(
            emails: [inboxA, inboxB, archivedB],
            accountScope: .all
        )

        #expect(snapshot.inbox.count == 2)
        #expect(snapshot.archive.count == 1)
    }

    @Test func singleAccountScopeFiltersMailboxesAndSearch() {
        let accountA = UUID()
        let accountB = UUID()
        let inbox = Self.email(accountID: accountA, subject: "Inbox")
        let flagged = Self.email(accountID: accountA, subject: "Flagged", isFlagged: true)
        let archived = Self.email(accountID: accountA, subject: "Archive", isArchived: true)
        let trash = Self.email(accountID: accountA, subject: "Trash", isTrashed: true)
        let searchable = Self.email(accountID: accountA, subject: "Needle project")
        let otherAccount = Self.email(accountID: accountB, subject: "Needle other account")

        let snapshot = EmailThreadScopeSnapshot(
            emails: [inbox, flagged, archived, trash, searchable, otherAccount],
            accountScope: .account(accountA)
        )

        #expect(snapshot.threads(for: .inbox).count == 3)
        #expect(snapshot.threads(for: .flagged).count == 1)
        #expect(snapshot.threads(for: .archive).count == 1)
        #expect(snapshot.threads(for: .trash).count == 1)
        #expect(snapshot.search(.inbox, with: "Needle").map(\.latestMessage?.accountID) == [accountA])
    }

    @Test func roleAwarePartitionsKeepSentInInboxAndExposeCustomFolders() {
        let accountID = UUID()
        let inbox = Self.email(accountID: accountID, subject: "Inbox")
        let sent = Self.email(accountID: accountID, subject: "Sent", role: .sent)
        let drafts = Self.email(accountID: accountID, subject: "Drafts", role: .drafts)
        let junk = Self.email(accountID: accountID, subject: "Junk", role: .junk)
        let custom = Self.email(accountID: accountID, subject: "Receipts", mailbox: "Work/Receipts", role: .custom)

        let snapshot = EmailThreadScopeSnapshot(
            emails: [inbox, sent, drafts, junk, custom],
            accountScope: .account(accountID)
        )

        #expect(snapshot.threads(for: .inbox).count == 2)
        #expect(snapshot.threads(for: .sent).count == 1)
        #expect(snapshot.threads(for: .drafts).count == 1)
        #expect(snapshot.threads(for: .junk).count == 1)
        #expect(snapshot.customFolderNames == ["Work/Receipts"])
        #expect(snapshot.threads(for: .custom("Work/Receipts")).count == 1)
    }

    @Test func visibleMailboxesGateCustomFolders() {
        let accountID = UUID()
        let custom = Self.email(accountID: accountID, subject: "Receipts", mailbox: "Work/Receipts", role: .custom)
        let snapshot = EmailThreadScopeSnapshot(emails: [custom], accountScope: .all)

        #expect(snapshot.visibleMailboxes(showCustomFolders: true).contains(.custom("Work/Receipts")))
        #expect(snapshot.visibleMailboxes(showCustomFolders: false) == [.inbox, .flagged])
    }

    @Test func removedSelectedAccountFallsBackToAllAccounts() {
        let existing = UUID()
        let removed = UUID()
        let accounts = [
            StoredEmailAccount(
                id: existing,
                displayName: "Existing",
                imapHost: "imap.example.com",
                imapUsername: "existing@example.com",
                smtpHost: "smtp.example.com",
                smtpUsername: "existing@example.com",
                fromAddress: "existing@example.com"
            )
        ]

        #expect(EmailAccountScope.account(removed).normalized(availableAccounts: accounts) == .all)
        #expect(EmailAccountScope.account(existing).normalized(availableAccounts: accounts) == .account(existing))
    }

    private static func email(
        accountID: UUID,
        subject: String,
        mailbox: String = "INBOX",
        role: MailFolderRole = .inbox,
        isFlagged: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false
    ) -> Email {
        let thread = EmailThread(accountID: accountID, subjectNormalized: subject)
        let email = Email(
            subject: subject,
            bodyText: subject,
            mailbox: mailbox,
            role: role,
            isFlagged: isFlagged,
            isArchived: isArchived,
            isTrashed: isTrashed,
            accountID: accountID,
            thread: thread
        )
        thread.messages = [email]
        return email
    }
}
