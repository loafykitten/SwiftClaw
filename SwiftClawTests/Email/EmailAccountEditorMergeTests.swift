import Foundation
import Testing
@testable import SwiftClaw

/// `StoredEmailAccount.applyingEditorFields`: saving the account editor must
/// not drop state the editor doesn't own (review-folder opt-ins, the folder
/// catalog, resolved special-use folders).
struct EmailAccountEditorMergeTests {
    private static func resolvedAccount() -> StoredEmailAccount {
        StoredEmailAccount(
            displayName: "Work",
            imapHost: "imap.work.example.com",
            imapPort: 993,
            imapUsername: "alex@work.example.com",
            smtpHost: "smtp.work.example.com",
            smtpPort: 587,
            smtpUsername: "alex@work.example.com",
            fromAddress: "alex@work.example.com",
            archiveMailbox: "Archive",
            trashMailbox: "Deleted Items",
            sentMailbox: "Sent Items",
            draftsMailbox: "Drafts",
            junkMailbox: "Junk",
            folders: [MailFolderDescriptor(name: "Projects", role: .custom, delimiter: "/")],
            reviewIncludedMailboxes: ["Projects"]
        )
    }

    private static func apply(
        to account: StoredEmailAccount,
        displayName: String? = nil,
        imapHost: String? = nil,
        imapPort: Int? = nil,
        imapUsername: String? = nil
    ) -> StoredEmailAccount {
        account.applyingEditorFields(
            displayName: displayName ?? account.displayName,
            imapHost: imapHost ?? account.imapHost,
            imapPort: imapPort ?? account.imapPort,
            imapUsername: imapUsername ?? account.imapUsername,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            smtpUsername: account.smtpUsername,
            fromAddress: account.fromAddress
        )
    }

    @Test func displayNameEditPreservesFolderStateAndPreferences() {
        let original = Self.resolvedAccount()
        let edited = Self.apply(to: original, displayName: "Day job")

        #expect(edited.id == original.id)
        #expect(edited.displayName == "Day job")
        #expect(edited.reviewIncludedMailboxes == ["Projects"])
        #expect(edited.folders == original.folders)
        #expect(edited.trashMailbox == "Deleted Items")
        #expect(edited.sentMailbox == "Sent Items")
        #expect(edited.junkMailbox == "Junk")
    }

    @Test func portOrHostCaseChangeKeepsTheSameServerCaches() {
        let original = Self.resolvedAccount()
        let edited = Self.apply(to: original, imapHost: "IMAP.work.example.com", imapPort: 143)
        #expect(edited.folders == original.folders)
        #expect(edited.archiveMailbox == "Archive")
    }

    @Test func serverChangeClearsConnectionCachesButKeepsPreferences() {
        let original = Self.resolvedAccount()
        for edited in [
            Self.apply(to: original, imapHost: "imap.other.example.com"),
            Self.apply(to: original, imapUsername: "sam@work.example.com"),
        ] {
            #expect(edited.folders == nil)
            #expect(edited.archiveMailbox == nil)
            #expect(edited.trashMailbox == nil)
            #expect(edited.sentMailbox == nil)
            #expect(edited.draftsMailbox == nil)
            #expect(edited.junkMailbox == nil)
            #expect(edited.reviewIncludedMailboxes == ["Projects"])
        }
    }
}
