import Foundation
import SwiftData

@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var title: String
    var modelSelection: String
    var reasoningEffortRaw: String?
    var createdAt: Date
    var updatedAt: Date
    var isGenerating: Bool
    var isPinned: Bool = false
    var isArchived: Bool = false
    var errorMessage: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.chat)
    var messages: [ChatMessage]

    var reasoningEffort: ModelReasoningEffort {
        get {
            guard let raw = reasoningEffortRaw else { return .off }
            return ModelReasoningEffort(rawValue: raw) ?? .off
        }
        set {
            reasoningEffortRaw = newValue.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        modelSelection: String,
        reasoningEffort: ModelReasoningEffort = .off,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isGenerating: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        errorMessage: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.modelSelection = modelSelection
        self.reasoningEffortRaw = reasoningEffort.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isGenerating = isGenerating
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.errorMessage = errorMessage
        self.messages = messages
    }

    var visibleMessages: [ChatMessage] {
        sortedMessages.filter { $0.role != .system }
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.sortIndex < rhs.sortIndex
            }

            return lhs.createdAt < rhs.createdAt
        }
    }

    var latestVisibleMessageDate: Date {
        messages.lazy
            .filter { $0.role != .system }
            .map(\.createdAt)
            .max() ?? updatedAt
    }

    func appendMessage(
        role: ChatMessageRole,
        content: String,
        imageAttachments: [ImageAttachmentRecord] = []
    ) {
        let nextIndex = (messages.map(\.sortIndex).max() ?? -1) + 1
        let message = ChatMessage(
            role: role,
            content: content,
            sortIndex: nextIndex,
            imageAttachments: imageAttachments
        )
        message.chat = self
        messages.append(message)
        updatedAt = .now
    }
}

enum ChatListOrdering {
    static func sorted(_ chats: [Chat], pinnedFirst: Bool = true) -> [Chat] {
        chats.sorted { lhs, rhs in
            if pinnedFirst, lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }

            let lhsDate = lhs.latestVisibleMessageDate
            let rhsDate = rhs.latestVisibleMessageDate
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

extension Chat {
    /// Title prefix stamped on chats created by the email review pass. This
    /// is the app-wide discriminator for review chats — completion tool
    /// wiring, title regeneration, sidebar rendering, and the review
    /// scheduler's unread guard all key off it via `isEmailReviewChat`.
    static let emailReviewTitlePrefix = "Inbox review —"

    /// Whether this chat was created by the email review pass. A chat *is* a
    /// review chat for its whole life — keyed off the title stamped at
    /// creation, not off whether its card still has live emails.
    var isEmailReviewChat: Bool {
        title.hasPrefix(Self.emailReviewTitlePrefix)
    }

    func matchesSearch(_ searchText: String) -> Bool {
        SearchQuery.matches(searchText, in: searchValues)
    }

    private var searchValues: [String] {
        [title, modelSelection] + visibleMessages.map(\.content)
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRawValue: String
    var content: String
    var imageAttachmentsData: Data?
    var reviewCardData: Data?
    var createdAt: Date
    var sortIndex: Int
    var chat: Chat?

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        createdAt: Date = .now,
        sortIndex: Int,
        imageAttachments: [ImageAttachmentRecord] = [],
        reviewCard: ReviewCardPayload? = nil
    ) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.content = content
        self.imageAttachmentsData = Self.encodeImageAttachments(imageAttachments)
        self.reviewCardData = Self.encodeReviewCard(reviewCard)
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }

    var role: ChatMessageRole {
        get {
            ChatMessageRole(rawValue: roleRawValue) ?? .assistant
        }
        set {
            roleRawValue = newValue.rawValue
        }
    }

    var inferenceMessage: InferenceMessage? {
        inferenceMessage(includingImages: true)
    }

    var imageAttachments: [ImageAttachmentRecord] {
        get {
            guard let imageAttachmentsData,
                  !imageAttachmentsData.isEmpty,
                  let attachments = try? JSONDecoder().decode(
                    [ImageAttachmentRecord].self,
                    from: imageAttachmentsData
                  ) else {
                return []
            }

            return attachments
        }
        set {
            imageAttachmentsData = Self.encodeImageAttachments(newValue)
        }
    }

    var reviewCard: ReviewCardPayload? {
        get {
            guard let reviewCardData,
                  !reviewCardData.isEmpty,
                  let payload = try? JSONDecoder().decode(
                    ReviewCardPayload.self,
                    from: reviewCardData
                  ) else {
                return nil
            }

            return payload
        }
        set {
            reviewCardData = Self.encodeReviewCard(newValue)
        }
    }

    func inferenceMessage(includingImages: Bool) -> InferenceMessage? {
        switch role {
        case .system:
            .system(content)
        case .user:
            .user(content, imageAttachments: includingImages ? imageAttachments : [])
        case .assistant:
            .assistant(content)
        }
    }

    private static func encodeImageAttachments(_ attachments: [ImageAttachmentRecord]) -> Data? {
        guard !attachments.isEmpty,
              let data = try? JSONEncoder().encode(attachments) else {
            return nil
        }

        return data
    }

    private static func encodeReviewCard(_ payload: ReviewCardPayload?) -> Data? {
        guard let payload,
              let data = try? JSONEncoder().encode(payload) else {
            return nil
        }

        return data
    }
}

enum ChatMessageRole: String, Codable {
    case system
    case user
    case assistant
}

enum ChatDefaults {
    static func title(for input: String) -> String {
        let singleLine = input
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? input
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "New Chat"
        }

        if trimmed.count <= 60 {
            return trimmed
        }

        return String(trimmed.prefix(57)) + "..."
    }
}
