import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct WorkspaceEmailSummaryTests {
    @Test func countsOnlyActiveMessages() {
        let activeUnread = Self.email(thread: EmailThread(subjectNormalized: "a"), isRead: false)
        let activeFlagged = Self.email(thread: EmailThread(subjectNormalized: "b"), isRead: true, isFlagged: true)
        let activeNotated = Self.email(thread: EmailThread(subjectNormalized: "c"), isRead: true, noteCount: 1)
        let archived = Self.email(
            thread: EmailThread(subjectNormalized: "d"),
            isRead: false,
            isFlagged: true,
            isArchived: true,
            noteCount: 1
        )
        let deleted = Self.email(
            thread: EmailThread(subjectNormalized: "e"),
            isRead: false,
            isFlagged: true,
            isDeleted: true,
            noteCount: 1
        )

        for email in [activeUnread, activeFlagged, activeNotated, archived, deleted] {
            email.thread?.messages = [email]
        }

        let summary = WorkspaceEmailSummary(
            emails: [activeUnread, activeFlagged, activeNotated, archived, deleted]
        )

        #expect(summary.unreadCount == 1)
        #expect(summary.inboxThreadCount == 3)
        #expect(summary.flaggedThreadCount == 1)
        #expect(summary.notatedThreadCount == 1)
    }

    @Test func countsThreadsNotMessages() {
        // Two visible messages in one thread (one flagged + notated, both from
        // the same conversation) must register as a single inbox/flagged/
        // notated thread — matching the one row the mailbox lists show.
        let thread = EmailThread(subjectNormalized: "conversation")
        let first = Self.email(thread: thread, isRead: true, isFlagged: true, noteCount: 1)
        let second = Self.email(thread: thread, isRead: true, isFlagged: true, noteCount: 2)
        thread.messages = [first, second]

        let summary = WorkspaceEmailSummary(emails: [first, second])

        #expect(summary.inboxThreadCount == 1)
        #expect(summary.flaggedThreadCount == 1)
        #expect(summary.notatedThreadCount == 1)
    }

    @Test func ignoresThreadsWithNoVisibleMessages() {
        // A thread whose only messages are archived/deleted has left the
        // inbox, even if those messages are flagged or notated.
        let archivedThread = EmailThread(subjectNormalized: "done")
        let archivedMessage = Self.email(
            thread: archivedThread,
            isRead: true,
            isFlagged: true,
            isArchived: true,
            noteCount: 1
        )
        archivedThread.messages = [archivedMessage]

        // Flag/note on an archived message doesn't count while a sibling
        // visible message keeps the thread in the inbox.
        let mixedThread = EmailThread(subjectNormalized: "mixed")
        let visible = Self.email(thread: mixedThread, isRead: true)
        let archivedFlagged = Self.email(
            thread: mixedThread,
            isRead: true,
            isFlagged: true,
            isArchived: true,
            noteCount: 1
        )
        mixedThread.messages = [visible, archivedFlagged]

        let summary = WorkspaceEmailSummary(emails: [archivedMessage, visible, archivedFlagged])

        #expect(summary.inboxThreadCount == 1)
        #expect(summary.flaggedThreadCount == 0)
        #expect(summary.notatedThreadCount == 0)
    }

    private static func email(
        thread: EmailThread? = nil,
        isRead: Bool,
        isFlagged: Bool = false,
        isArchived: Bool = false,
        isDeleted: Bool = false,
        noteCount: Int = 0,
        date: Date = .now
    ) -> Email {
        let email = Email(
            date: date,
            isRead: isRead,
            isFlagged: isFlagged,
            isArchived: isArchived,
            isDeleted: isDeleted,
            thread: thread
        )
        email.notes = (0..<noteCount).map { index in
            EmailNote(email: email, content: "Note \(index)")
        }
        return email
    }
}
