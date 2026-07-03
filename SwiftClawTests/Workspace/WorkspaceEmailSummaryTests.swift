import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct WorkspaceEmailSummaryTests {
    @Test func countsOnlyActiveMessages() {
        let activeUnread = Self.email(isRead: false)
        let activeFlagged = Self.email(isRead: true, isFlagged: true)
        let activeNotated = Self.email(isRead: true, noteCount: 1)
        let archived = Self.email(isRead: false, isFlagged: true, isArchived: true, noteCount: 1)
        let deleted = Self.email(isRead: false, isFlagged: true, isDeleted: true, noteCount: 1)

        let summary = WorkspaceEmailSummary(
            emails: [activeUnread, activeFlagged, activeNotated, archived, deleted]
        )

        #expect(summary.unreadCount == 1)
        #expect(summary.newCount == 3)
        #expect(summary.flaggedCount == 1)
        #expect(summary.notatedCount == 1)
    }

    @Test func countsNewMessagesSinceReview() {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let reviewedThread = EmailThread(subjectNormalized: "reviewed", lastReviewedAt: base)
        let neverReviewedThread = EmailThread(subjectNormalized: "fresh")

        let olderReviewed = Self.email(thread: reviewedThread, isRead: true, date: base.addingTimeInterval(-10))
        let newerReviewed = Self.email(thread: reviewedThread, isRead: true, date: base.addingTimeInterval(10))
        let neverReviewed = Self.email(thread: neverReviewedThread, isRead: true, date: base.addingTimeInterval(-10))
        let archivedNewer = Self.email(
            thread: reviewedThread,
            isRead: true,
            isArchived: true,
            date: base.addingTimeInterval(20)
        )
        let deletedNewer = Self.email(
            thread: reviewedThread,
            isRead: true,
            isDeleted: true,
            date: base.addingTimeInterval(20)
        )

        let summary = WorkspaceEmailSummary(
            emails: [olderReviewed, newerReviewed, neverReviewed, archivedNewer, deletedNewer]
        )

        #expect(summary.newCount == 2)
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
