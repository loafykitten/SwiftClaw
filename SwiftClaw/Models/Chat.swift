import Foundation
import SwiftData

@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var title: String
    var modelSelection: String
    var createdAt: Date
    var updatedAt: Date
    var isGenerating: Bool
    var isPinned: Bool = false
    var errorMessage: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.chat)
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String,
        modelSelection: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isGenerating: Bool = false,
        isPinned: Bool = false,
        errorMessage: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.modelSelection = modelSelection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isGenerating = isGenerating
        self.isPinned = isPinned
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

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRawValue: String
    var content: String
    var imageAttachmentsData: Data?
    var createdAt: Date
    var sortIndex: Int
    var chat: Chat?

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        createdAt: Date = .now,
        sortIndex: Int,
        imageAttachments: [ImageAttachmentRecord] = []
    ) {
        self.id = id
        self.roleRawValue = role.rawValue
        self.content = content
        self.imageAttachmentsData = Self.encodeImageAttachments(imageAttachments)
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
}

enum ChatMessageRole: String, Codable {
    case system
    case user
    case assistant
}

enum ChatDefaults {
    static let systemPrompt = """
        You are SwiftClaw, a helpful personal AI assistant. Be clear, practical, and concise.
        """

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
