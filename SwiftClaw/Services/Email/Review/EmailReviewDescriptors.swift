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

    /// Builds the prompt snapshot for a thread from exactly the messages the
    /// review selection considered (`EmailRepository.consideredMessages`), so
    /// the payload honors the same folder scope that picked the thread:
    /// excluded custom folders stay out, and explicitly requested Junk/Drafts
    /// messages stay in even beside Inbox mail. Falls back to all messages
    /// only when handed an empty set.
    @MainActor
    static func make(for thread: EmailThread, messages selected: [Email]) -> EmailReviewThreadDescriptor {
        let source = selected.isEmpty ? thread.sortedMessages : selected.sorted { $0.date < $1.date }
        let latest = source.last
        let messages = source.map { message in
            EmailReviewMessageDescriptor(
                messageID: message.id,
                subject: message.subject,
                fromAddress: message.displayFromAddress,
                date: EmailReviewDateFormatter.string(from: message.date),
                folder: message.mailbox,
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
            participantSummary: thread.participantSummary(for: source),
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
    let folder: String
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
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func string(from date: Date) -> String {
        lock.withLock { formatter.string(from: date) }
    }
}
