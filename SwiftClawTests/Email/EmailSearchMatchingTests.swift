import Foundation
@testable import SwiftClaw
import Testing

struct EmailSearchMatchingTests {
    @Test func matchesMessageFieldsNotesAndAttachments() {
        let email = Email(
            messageID: "<alpha@example.com>",
            subject: "Quarterly Launch Plan",
            fromAddress: "marina@example.com",
            toAddresses: ["ember@example.com"],
            ccAddresses: ["ops@example.com"],
            bodyText: "The checklist needs a calmer rollout.",
            mailbox: "INBOX",
            notes: [
                EmailNote(author: .user, content: "Revisit after invoices clear."),
            ],
            attachments: [
                EmailAttachment(filename: "budget.xlsx"),
            ]
        )
        let thread = EmailThread(subjectNormalized: "quarterly launch plan", messages: [email])
        email.thread = thread

        #expect(thread.matchesSearch("launch"))
        #expect(thread.matchesSearch("marina checklist"))
        #expect(thread.matchesSearch("ops invoices"))
        #expect(thread.matchesSearch("budget"))
        #expect(!thread.matchesSearch("vacation"))
    }

    @Test func ignoresInternalRoutingFields() {
        let email = Email(
            messageID: "<alpha@example.com>",
            subject: "Hello",
            inReplyTo: "<beta@example.com>",
            referencesRaw: ["<gamma@example.com>"]
        )
        let thread = EmailThread(subjectNormalized: "hello", messages: [email])
        email.thread = thread

        #expect(!thread.matchesSearch("alpha"))
        #expect(!thread.matchesSearch("beta"))
        #expect(!thread.matchesSearch("gamma"))
        #expect(!thread.matchesSearch("inbox"))
    }

    @Test func matchesHTMLOnlyBodies() {
        let email = Email(
            subject: "Newsletter",
            bodyHTML: "<p>Fresh <b>croissant</b> recipes inside.</p>"
        )
        let thread = EmailThread(subjectNormalized: "newsletter", messages: [email])
        email.thread = thread

        #expect(thread.matchesSearch("croissant"))
    }

    @Test func htmlPlainTextCacheInvalidatesWhenBodyChanges() {
        let email = Email(subject: "Newsletter", bodyHTML: "<p>First edition</p>")

        #expect(email.plainTextBody == "First edition")
        email.bodyHTML = "<p>Second edition</p>"
        #expect(email.plainTextBody == "Second edition")
    }

    @Test func emptyQueryMatchesEverything() {
        let thread = EmailThread(subjectNormalized: "empty")

        #expect(thread.matchesSearch(""))
        #expect(thread.matchesSearch("   "))
    }
}
