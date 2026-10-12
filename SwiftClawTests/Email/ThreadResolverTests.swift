import Foundation
import Testing
@testable import SwiftClaw

struct ThreadResolverTests {
    @Test func clustersMessagesBySharedMessageIDAncestry() {
        let msgA = makeEmail(
            subject: "Project sync",
            messageID: "<a@example.com>",
            references: [],
            inReplyTo: nil
        )
        let msgB = makeEmail(
            subject: "Re: Project sync",
            messageID: "<b@example.com>",
            references: [],
            inReplyTo: "<a@example.com>"
        )
        let msgC = makeEmail(
            subject: "Re: Project sync",
            messageID: "<c@example.com>",
            references: ["<a@example.com>", "<b@example.com>"],
            inReplyTo: "<b@example.com>"
        )

        let threads = ThreadResolver.cluster([msgA, msgB, msgC])

        #expect(threads.count == 1)
        #expect(threads[0].messages.count == 3)
    }

    @Test func clustersByNormalizedSubjectWithReplyMarkers() {
        let msgA = makeEmail(
            subject: "Lunch?",
            messageID: "<l1@example.com>",
            references: [],
            inReplyTo: nil
        )
        let msgB = makeEmail(
            subject: "RE: Lunch?",
            messageID: "<l2@example.com>",
            references: [],
            inReplyTo: nil
        )
        let msgC = makeEmail(
            subject: "Re: Fwd: Lunch?",
            messageID: "<l3@example.com>",
            references: [],
            inReplyTo: nil
        )

        let threads = ThreadResolver.cluster([msgA, msgB, msgC])

        // All three share normalized subject "Lunch?" and at least one carries
        // a reply marker, so they cluster into one thread.
        #expect(threads.count == 1)
    }

    @Test func doesNotClusterUnrelatedMessagesWithoutReplyMarkers() {
        let msgA = makeEmail(
            subject: "Lunch?",
            messageID: "<x1@example.com>",
            references: [],
            inReplyTo: nil
        )
        let msgB = makeEmail(
            subject: "Lunch?",
            messageID: "<x2@example.com>",
            references: [],
            inReplyTo: nil
        )

        let threads = ThreadResolver.cluster([msgA, msgB])

        // Same subject but neither carries a reply marker → treated as
        // unrelated (e.g. two separate "Lunch?" threads from different people).
        #expect(threads.count == 2)
    }

    @Test func strippingSubjectPrefixesIsIdempotent() {
        #expect(ThreadResolver.normalizedSubject("Re: Re: Fwd: Hello") == "Hello")
        #expect(ThreadResolver.normalizedSubject("[swift-evolution] Re: Pitch") == "Pitch")
        #expect(ThreadResolver.normalizedSubject("  RE:  WG:  Title  ") == "Title")
    }

    // MARK: - Helpers

    private func makeEmail(
        subject: String,
        messageID: String,
        references: [String],
        inReplyTo: String?
    ) -> Email {
        Email(
            messageID: messageID,
            subject: subject,
            fromAddress: "sender@example.com",
            toAddresses: ["recipient@example.com"],
            ccAddresses: [],
            bccAddresses: [],
            date: .now,
            receivedAt: .now,
            bodyText: "body",
            bodyHTML: nil,
            mailbox: "INBOX",
            isRead: false,
            isFlagged: false,
            isArchived: false,
            isTrashed: false,
            inReplyTo: inReplyTo,
            referencesRaw: references,
            uid: 1,
            thread: nil,
            notes: [],
            attachments: []
        )
    }
}
