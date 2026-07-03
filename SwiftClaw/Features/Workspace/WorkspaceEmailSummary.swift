import Foundation

@MainActor
struct WorkspaceEmailSummary: Equatable {
    let unreadCount: Int
    let inboxThreadCount: Int
    let flaggedThreadCount: Int
    let notatedThreadCount: Int

    init(emails: [Email]) {
        // Same partition as `EmailView.inboxThreads`: a thread belongs to the
        // inbox while it still has at least one visible message, so the tile
        // count always agrees with the Inbox list the widget navigates to.
        let activeEmails = emails.filter { !$0.isArchived && !$0.isDeleted }
        unreadCount = activeEmails.filter { !$0.isRead }.count

        var seen = Set<UUID>()
        let activeThreads = activeEmails.compactMap { email -> EmailThread? in
            guard let thread = email.thread else { return nil }
            guard seen.insert(thread.id).inserted else { return nil }
            return thread
        }
        inboxThreadCount = activeThreads.count
        flaggedThreadCount = activeThreads.filter(\.isReviewFlagged).count
        notatedThreadCount = activeThreads.filter(\.hasReviewNote).count
    }

    static let empty = WorkspaceEmailSummary(emails: [])
}
