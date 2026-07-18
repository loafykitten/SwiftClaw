import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct ChatCompletionServiceTests {
    @Test func nonVisionModelSelectionProducesNoImageAttachments() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        SettingsStorage.saveProviderModels(
            [ProviderModel(name: "text-only", capabilities: [.tools])],
            forKey: SettingsKeys.neuralwattModels,
            userDefaults: fixture.defaults
        )
        let capabilities = SettingsStorage.capabilities(
            for: "Neuralwatt: text-only",
            userDefaults: fixture.defaults
        )
        let attachment = ImageAttachmentRecord(
            filePath: "/tmp/image.jpg",
            byteCount: 10,
            pixelWidth: 10,
            pixelHeight: 10
        )
        let message = ChatMessage(
            role: .user,
            content: "Describe this",
            sortIndex: 0,
            imageAttachments: [attachment]
        )

        let messages = ChatCompletionService.persistedInferenceMessages(
            from: [message],
            includingImages: capabilities.contains(.vision)
        )

        #expect(messages == [.user("Describe this", imageAttachments: [])])
    }

    @Test func onlyMostRecentUserTurnKeepsImageAttachments() {
        let oldAttachment = Self.attachment(path: "/tmp/old.jpg")
        let newestAttachment = Self.attachment(path: "/tmp/new.jpg")
        let messages = [
            ChatMessage(
                role: .user,
                content: "Old",
                sortIndex: 0,
                imageAttachments: [oldAttachment]
            ),
            ChatMessage(role: .assistant, content: "Reply", sortIndex: 1),
            ChatMessage(
                role: .user,
                content: "Newest",
                sortIndex: 2,
                imageAttachments: [newestAttachment]
            ),
        ]

        let inferenceMessages = ChatCompletionService.persistedInferenceMessages(
            from: messages,
            includingImages: true
        )

        #expect(inferenceMessages == [
            .user("Old", imageAttachments: []),
            .assistant("Reply"),
            .user("Newest", imageAttachments: [newestAttachment]),
        ])
    }

    private static func attachment(path: String) -> ImageAttachmentRecord {
        ImageAttachmentRecord(
            filePath: path,
            byteCount: 10,
            pixelWidth: 10,
            pixelHeight: 10
        )
    }
}
