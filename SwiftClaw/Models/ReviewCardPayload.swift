import Foundation
import SwiftUI

enum ReviewType: String, Codable, Sendable {
    case email
    case calendar
    case reminders
    /// Forward-compat bucket for review types this build doesn't know about.
    /// An unknown `reviewType` decodes to `.unknown` instead of throwing —
    /// that way the whole payload isn't silently dropped (`try?` returns nil)
    /// and the registry can render a generic card.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReviewType(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ReviewActionToken: String, Codable, Sendable, CaseIterable, Identifiable {
    case review
    case flag
    case reply
    case delete
    case archive

    var id: String { rawValue }

    /// Human-readable label shown on buttons + review-card context menus.
    var displayName: String {
        switch self {
        case .review: "Review"
        case .flag: "Flag"
        case .reply: "Reply"
        case .delete: "Delete"
        case .archive: "Archive"
        }
    }

    /// SwiftUI button role — only `delete` is destructive; the rest are plain.
    var role: ButtonRole? {
        switch self {
        case .delete: .destructive
        default: nil
        }
    }
}

struct ReviewItem: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var itemID: UUID
    var actionToken: String
    var actionLabel: String
    var summary: String?
    var subject: String?
    var sender: String?
    var date: String?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        actionToken: ReviewActionToken,
        actionLabel: String,
        summary: String? = nil,
        subject: String? = nil,
        sender: String? = nil,
        date: String? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.actionToken = actionToken.rawValue
        self.actionLabel = actionLabel
        self.summary = summary
        self.subject = subject
        self.sender = sender
        self.date = date
    }

    var action: ReviewActionToken? {
        ReviewActionToken(rawValue: actionToken)
    }
}

struct ReviewCardPayload: Codable, Sendable, Hashable {
    var reviewType: ReviewType
    var items: [ReviewItem]
}
