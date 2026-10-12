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
    var latestVisibleMessageAt: Date?
    var isGenerating: Bool
    var isPinned: Bool = false
    var isArchived: Bool = false
    var errorMessage: String?
    /// Set on chats spawned from a Deep Research report ("Ask a follow-up"):
    /// completions append a request-bound `research_report` tool so the model
    /// can read the stored report on demand.
    var researchSessionID: UUID?

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
        latestVisibleMessageAt: Date? = nil,
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
        self.latestVisibleMessageAt = latestVisibleMessageAt
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
        if let latestVisibleMessageAt {
            return latestVisibleMessageAt
        }

        let derived = messages.lazy
            .filter { $0.role != .system }
            .map(\.createdAt)
            .max()
        guard let derived else {
            return updatedAt
        }
        latestVisibleMessageAt = derived
        return derived
    }

    @discardableResult
    func appendMessage(
        role: ChatMessageRole,
        content: String,
        imageAttachments: [ImageAttachmentRecord] = [],
        reviewCard: ReviewCardPayload? = nil
    ) -> ChatMessage {
        let nextIndex = (messages.map(\.sortIndex).max() ?? -1) + 1
        let message = ChatMessage(
            role: role,
            content: content,
            sortIndex: nextIndex,
            imageAttachments: imageAttachments,
            reviewCard: reviewCard
        )
        message.chat = self
        messages.append(message)
        noteMessageChanged(message)
        updatedAt = .now
        return message
    }

    /// Reverses an `appendMessage` whose save failed, so a later save of the
    /// context can't persist a message whose attachment files were already
    /// rolled back (and a resend doesn't duplicate it).
    func discardUnsavedMessage(
        _ message: ChatMessage,
        in modelContext: ModelContext,
        restoringUpdatedAt previousUpdatedAt: Date
    ) {
        messages.removeAll { $0.id == message.id }
        modelContext.delete(message)
        refreshLatestVisibleMessageAt()
        updatedAt = previousUpdatedAt
    }

    /// Invalidation is explicit, not observed: property observers on @Model
    /// stored properties are unreliable, and no production path mutates a
    /// message's role/date or reparents it after creation (content edits
    /// don't affect createdAt-based recency). `appendMessage` calls this;
    /// any future mutation of a message's role, date, or chat must call
    /// `refreshLatestVisibleMessageAt()` itself.
    func noteMessageChanged(_ message: ChatMessage) {
        if message.role == .system {
            refreshLatestVisibleMessageAt()
        } else if let latestVisibleMessageAt {
            self.latestVisibleMessageAt = max(latestVisibleMessageAt, message.createdAt)
        } else {
            refreshLatestVisibleMessageAt()
        }
    }

    func refreshLatestVisibleMessageAt() {
        latestVisibleMessageAt = messages.lazy
            .filter { $0.role != .system }
            .map(\.createdAt)
            .max()
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
    static let calendarReviewTitlePrefix = "Calendar review —"
    static let remindersReviewTitlePrefix = "Reminders review —"
    static let notesReviewTitlePrefix = "Notes review —"
    /// Fallback destination for `propose_memory` cards when the review run
    /// that raised them produced no review chat of its own — see
    /// `MemoryReviewProposalRouter`.
    static let memorySuggestionsTitlePrefix = "Memory suggestions —"

    /// Whether this chat was created by the email review pass. A chat *is* a
    /// review chat for its whole life — keyed off the title stamped at
    /// creation, not off whether its card still has live emails.
    var isEmailReviewChat: Bool {
        title.hasPrefix(Self.emailReviewTitlePrefix)
    }

    /// Whether this chat was created by the calendar review pass (same
    /// title-prefix contract as `isEmailReviewChat`).
    var isCalendarReviewChat: Bool {
        title.hasPrefix(Self.calendarReviewTitlePrefix)
    }

    /// Whether this chat was created by the reminders review pass (same
    /// title-prefix contract as `isEmailReviewChat`).
    var isRemindersReviewChat: Bool {
        title.hasPrefix(Self.remindersReviewTitlePrefix)
    }

    /// Whether this chat was created by the Notes vault-hygiene review pass.
    var isNotesReviewChat: Bool {
        title.hasPrefix(Self.notesReviewTitlePrefix)
    }

    /// Whether this chat was created as a `propose_memory` card fallback.
    var isMemorySuggestionsChat: Bool {
        title.hasPrefix(Self.memorySuggestionsTitlePrefix)
    }

    func matchesSearch(_ searchText: String) -> Bool {
        // Inactive search matches everything; bail before materializing
        // `searchValues`, which sorts and copies every visible message body.
        guard SearchQuery.isActive(searchText) else { return true }
        return SearchQuery.matches(searchText, in: searchValues)
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
