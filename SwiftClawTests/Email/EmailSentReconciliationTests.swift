import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Locks in the Phase-10 multi-mailbox behaviors: the upsert path promotes
/// a locally-synthetic Sent row (`upsertSentMessage`) to the real server
/// uid + clears `isLocallySynthetic` when the matching Message-ID arrives,
/// and Sent-mailbox deletion reconciliation preserves synthetic rows until
/// the real row lands.
@MainActor
struct EmailSentReconciliationTests {
    @Test func upsertPromotesSyntheticRowToRealServerUID() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let account = StoredEmailAccount(
            id: UUID(),
            displayName: "Test",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
        )

        // User sends a reply. `upsertSentMessage` synthesizes a local row
        // with a low synthetic uid + a Message-ID we control.
        let outgoing = OutgoingEmail(
            fromAddress: account.fromAddress,
            toAddresses: ["them@example.com"],
            subject: "Re: thread",
            bodyText: "reply body",
            messageID: "<r1@me.example.com>",
            inReplyTo: "<orig@them.example.com>"
        )
        guard let seededRow = repository.upsertSentMessage(
            outgoing,
            account: account,
            sentMailbox: "Sent"
        ) else {
            Issue.record("upsertSentMessage should return the seeded row")
            return
        }
        #expect(seededRow.isLocallySynthetic == true, "seeded row is synthetic")
        let syntheticUID = seededRow.uid
        #expect(syntheticUID > 0)

        // Later, a Sent-folder sync fetches the just-delivered message back
        // — same Message-ID, but with the real server-assigned uid. The
        // upsert path must NOT insert a duplicate; it must rewrite the
        // synthetic uid to the real one + clear the marker flag.
        let realUID = 9876
        let fetchedFromServer = FetchedMessage(
            uid: realUID,
            messageID: "<r1@me.example.com>",
            subject: "Re: thread",
            fromAddress: account.fromAddress,
            toAddresses: ["them@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            internalDate: .now,
            bodyText: "reply body",
            bodyHTML: nil,
            inReplyTo: "<orig@them.example.com>",
            references: [],
            isRead: true,
            isFlagged: false,
            mailbox: "Sent",
            attachmentDescriptors: []
        )
        let inserted = repository.upsertMessages(
            [fetchedFromServer],
            mailbox: "Sent",
            accountID: account.id
        )
        #expect(inserted == 0, "no duplicate insert — synthetic row promoted")

        // Confirm final state: exactly one row, with the real uid + marker
        // cleared.
        let allRows = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        #expect(allRows.count == 1, "exactly one row after promotion")
        let promoted = allRows.first
        #expect(promoted?.uid == realUID, "uid rewritten to the real server value")
        #expect(promoted?.isLocallySynthetic == false, "synthetic marker cleared")
    }

    @Test func reconcileDeletionsPreservesLocallySyntheticSentRows() async throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let repository = EmailRepository(modelContext: context)

        let accountID = UUID()
        // Seed a synthetic Sent row (simulating a just-sent reply that the
        // server hasn't echoed yet). Hard-code the row by inserting via the
        // repo so the synthetic flag is set the way production sets it.
        let account = StoredEmailAccount(
            id: accountID,
            displayName: "Test",
            imapHost: "imap.example.com",
            imapUsername: "me@example.com",
            smtpHost: "smtp.example.com",
            smtpUsername: "me@example.com",
            fromAddress: "me@example.com"
        )
        let outgoing = OutgoingEmail(
            fromAddress: account.fromAddress,
            toAddresses: ["them@example.com"],
            subject: "Re: re-thread",
            bodyText: "another reply",
            messageID: "<synthetic@me.example.com>"
        )
        let seeded = repository.upsertSentMessage(outgoing, account: account, sentMailbox: "Sent")
        #expect(seeded?.isLocallySynthetic == true)

        // Server Sent-mailbox UID set is EMPTY (the reply hasn't been
        // APPENDed yet). Reconciliation must NOT soft-delete the synthetic
        // row — preserveLocallySynthetic=true skips it, and the next Sent
        // sync reconciles it by messageID.
        let removed = repository.reconcileDeletions(
            serverUIDs: [],
            mailbox: "Sent",
            accountID: accountID,
            preserveLocallySynthetic: true
        )
        #expect(removed == 0, "synthetic Sent row must NOT be soft-deleted")

        let allRows = (try? context.fetch(FetchDescriptor<Email>())) ?? []
        #expect(allRows.count == 1, "row preserved")
        #expect(allRows.first?.isDeleted == false, "row still active")
        #expect(allRows.first?.isLocallySynthetic == true, "still flagged synthetic")
    }

    // MARK: - Helpers

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
