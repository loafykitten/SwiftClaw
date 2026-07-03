import Foundation

@MainActor
struct WorkspaceEmailSummary: Equatable {
    let unreadCount: Int
    let newCount: Int
    let flaggedCount: Int
    let notatedCount: Int

    init(emails: [Email]) {
        let activeEmails = emails.filter { !$0.isArchived && !$0.isDeleted }
        unreadCount = activeEmails.filter { !$0.isRead }.count
        newCount = activeEmails.filter(Self.isNewSinceReview).count
        flaggedCount = activeEmails.filter(\.isFlagged).count
        notatedCount = activeEmails.filter { !$0.notes.isEmpty }.count
    }

    static let empty = WorkspaceEmailSummary(emails: [])

    private static func isNewSinceReview(_ email: Email) -> Bool {
        guard let lastReviewedAt = email.thread?.lastReviewedAt else { return true }
        return lastReviewedAt < email.date
    }
}
