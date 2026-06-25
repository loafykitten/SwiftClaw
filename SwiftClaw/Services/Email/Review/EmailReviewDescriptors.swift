import Foundation

/// Snapshot of a thread used for building the AI review prompt. Decouples the
/// `EmailThread` SwiftData model from the prompt construction.
struct EmailReviewThreadDescriptor: Codable, Sendable {
    let threadID: UUID
    let subject: String
    let latestMessageDate: String
    let participantSummary: String
    let snippet: String
    let unreadCount: Int
    let isFlagged: Bool
    let messages: [EmailReviewMessageDescriptor]
}

struct EmailReviewMessageDescriptor: Codable, Sendable {
    let messageID: UUID
    let subject: String
    let fromAddress: String
    let date: String
    let snippet: String
    let isRead: Bool
    let isFlagged: Bool
    let notes: [EmailReviewNoteDescriptor]
}

struct EmailReviewNoteDescriptor: Codable, Sendable {
    let author: String
    let content: String
}

struct EmailReviewAction: Codable, Sendable {
    let emailGUID: String
    let actionToken: String
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case emailGUID = "email_guid"
        case actionToken = "action"
        case summary
    }
}

enum EmailReviewDateFormatter {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum EmailReviewDateContext {
    static func currentString(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timeZone

        return "Current user date/time: \(formatter.string(from: now)) (\(timeZone.identifier))"
    }
}
