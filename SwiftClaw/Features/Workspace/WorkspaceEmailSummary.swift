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
        var unreadCount = 0
        var inboxThreadCount = 0
        var flaggedThreadCount = 0
        var notatedThreadCount = 0
        var threadSignals: [UUID: (isFlagged: Bool, hasNote: Bool)] = [:]

        for email in emails where !email.isArchived && !email.isDeleted {
            if !email.isRead {
                unreadCount += 1
            }
            guard let threadID = email.thread?.id else { continue }

            let existing = threadSignals[threadID] ?? (false, false)
            if threadSignals[threadID] == nil {
                inboxThreadCount += 1
            }
            // Flag/note signals mirror `isReviewFlagged`/`hasReviewNote`,
            // which only consider reviewable roles — a flagged message in
            // Junk or Drafts must not mark the thread.
            let isReviewableRole = email.role != .junk && email.role != .drafts
            if email.isFlagged, isReviewableRole, !existing.isFlagged {
                flaggedThreadCount += 1
            }
            if !email.notes.isEmpty, isReviewableRole, !existing.hasNote {
                notatedThreadCount += 1
            }
            threadSignals[threadID] = (
                existing.isFlagged || (isReviewableRole && email.isFlagged),
                existing.hasNote || (isReviewableRole && !email.notes.isEmpty)
            )
        }

        self.unreadCount = unreadCount
        self.inboxThreadCount = inboxThreadCount
        self.flaggedThreadCount = flaggedThreadCount
        self.notatedThreadCount = notatedThreadCount
    }

    static let empty = WorkspaceEmailSummary(emails: [])
}

@MainActor
struct WorkspaceEmailWidgetContent: Equatable {
    let summary: WorkspaceEmailSummary
    let completeAccountCount: Int

    init(emails: [Email], accounts: [StoredEmailAccount]) {
        summary = WorkspaceEmailSummary(emails: emails)
        completeAccountCount = accounts.filter(\.isComplete).count
    }
}
