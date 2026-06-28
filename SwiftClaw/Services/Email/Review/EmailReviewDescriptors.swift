import Foundation

/// Snapshot of a thread used for building the AI review prompt. Decouples the
/// `EmailThread` SwiftData model from the prompt construction.
nonisolated struct EmailReviewThreadDescriptor: Codable, Sendable {
    let threadID: UUID
    let subject: String
    let latestMessageDate: String
    let participantSummary: String
    let snippet: String
    let unreadCount: Int
    let isFlagged: Bool
    let messages: [EmailReviewMessageDescriptor]

    /// Builds the prompt snapshot for a thread. Shared by the scheduled/manual
    /// review pass and the `fetch_inbox_emails` tool so both serialize threads
    /// identically. Describes the thread's reviewable (inbox) messages, falling
    /// back to all messages when the reviewable set is empty — the case when a
    /// fully archived or trashed thread is surfaced via an include flag.
    @MainActor
    static func make(for thread: EmailThread) -> EmailReviewThreadDescriptor {
        let reviewable = thread.reviewableMessages
        let source = reviewable.isEmpty ? thread.sortedMessages : reviewable
        let latest = source.last
        let messages = source.map { message in
            EmailReviewMessageDescriptor(
                messageID: message.id,
                subject: message.subject,
                fromAddress: message.fromAddress,
                date: EmailReviewDateFormatter.string(from: message.date),
                snippet: message.snippet,
                isRead: message.isRead,
                isFlagged: message.isFlagged,
                notes: message.sortedNoteDescriptors
            )
        }
        return EmailReviewThreadDescriptor(
            threadID: thread.id,
            subject: latest?.subject ?? "",
            latestMessageDate: latest.map { EmailReviewDateFormatter.string(from: $0.date) } ?? "",
            participantSummary: reviewable.isEmpty
                ? thread.participantSummary
                : thread.reviewParticipantSummary,
            snippet: latest?.snippet ?? "",
            unreadCount: source.filter { !$0.isRead }.count,
            isFlagged: source.contains { $0.isFlagged },
            messages: messages
        )
    }
}

extension Email {
    var sortedNoteDescriptors: [EmailReviewNoteDescriptor] {
        notes
            .sorted { $0.createdAt < $1.createdAt }
            .map { EmailReviewNoteDescriptor(author: $0.author.rawValue, content: $0.content) }
    }
}

nonisolated struct EmailReviewMessageDescriptor: Codable, Sendable {
    let messageID: UUID
    let subject: String
    let fromAddress: String
    let date: String
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    let notes: [EmailReviewNoteDescriptor]
}

nonisolated struct EmailReviewNoteDescriptor: Codable, Sendable {
    let author: String
    let content: String
}

nonisolated struct EmailReviewAction: Codable, Sendable {
    let emailGUID: String
    let actionToken: String
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case emailGUID = "email_guid"
        case actionToken = "action"
        case summary
    }
}

nonisolated enum EmailReviewDateFormatter {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

nonisolated enum EmailReviewDateContext {
    static func currentString(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timeZone

        return "Current user date/time: \(formatter.string(from: now)) (\(timeZone.identifier))"
    }
}
