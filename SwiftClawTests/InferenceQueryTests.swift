import Foundation
import OpenAI
import Testing
@testable import SwiftClaw

struct InferenceQueryTests {
    @Test func selectableReasoningEffortsDoNotIncludeMinimal() {
        #expect(ModelReasoningEffort.selectableCases == [.off, .low, .medium, .high])
    }

    @Test func encodesReasoningEfforts() throws {
        let cases: [(ModelReasoningEffort, String)] = [
            (.off, "none"),
            (.minimal, "minimal"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
        ]

        for (effort, rawValue) in cases {
            let query = InferenceService.makeChatQuery(
                messages: [.user(.init(content: .string("Hello")))],
                modelID: "test-model",
                temperature: nil,
                reasoningEffort: effort,
                tools: nil
            )
            let object = try Self.encodedObject(query)

            #expect(object["reasoning_effort"] as? String == rawValue)
        }
    }

    @Test func omitsReasoningEffortWhenUnset() throws {
        let query = InferenceService.makeChatQuery(
            messages: [.user(.init(content: .string("Hello")))],
            modelID: "test-model",
            temperature: nil,
            reasoningEffort: nil,
            tools: nil
        )
        let object = try Self.encodedObject(query)

        #expect(object["reasoning_effort"] == nil)
    }

    @Test func dropsReasoningEffortForModelsWithoutReasoningCapability() {
        #expect(
            InferenceService.effectiveReasoningEffort(
                .high,
                capabilities: [.json]
            ) == nil
        )
        #expect(
            InferenceService.effectiveReasoningEffort(
                .high,
                capabilities: [.reasoning, .json]
            ) == .high
        )
    }

    @Test func contextBudgetKeepsSystemContentAndNewestCompleteTurns() {
        let oldUser = String(repeating: "a", count: 20)
        let oldAssistant = String(repeating: "b", count: 20)
        let messages: [InferenceMessage] = [
            .system("system"),
            .user(oldUser),
            .assistant(oldAssistant),
            .user("new question"),
        ]

        let trimmed = InferenceService.messagesTrimmedToTokenBudget(messages, budget: 6)

        #expect(trimmed == [.system("system"), .user("new question")])
    }

    @Test func contextBudgetRetainsNewestTurnWhenItAloneExceedsBudget() {
        let trimmed = InferenceService.messagesTrimmedToTokenBudget(
            [.system("large system"), .user("the current user request")],
            budget: 1
        )

        #expect(trimmed == [.system("large system"), .user("the current user request")])
    }

    @Test func inferenceLayerOmitsImagePayloadsWithoutVisionCapability() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftclaw-inference-image-\(UUID().uuidString).jpg")
        try Data([0x01, 0x02, 0x03]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = ImageAttachmentRecord(
            filePath: url.path,
            byteCount: 3,
            pixelWidth: 1,
            pixelHeight: 1
        )

        let textOnlyParams = await InferenceService.chatParams(
            for: [.user("hello", imageAttachments: [attachment])],
            capabilities: [.tools]
        )
        let visionParams = await InferenceService.chatParams(
            for: [.user("hello", imageAttachments: [attachment])],
            capabilities: [.vision]
        )
        let textOnlyJSON = String(decoding: try JSONEncoder().encode(textOnlyParams), as: UTF8.self)
        let visionJSON = String(decoding: try JSONEncoder().encode(visionParams), as: UTF8.self)

        #expect(!textOnlyJSON.contains("image_url"))
        #expect(visionJSON.contains("image_url"))
    }

    @Test func prependsPersonaPromptToFeatureSystemPrompts() {
        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            [
                .system("Feature prompt"),
                .user("Hello"),
            ],
            systemPromptMode: .prependPersona,
            personaPrompt: "Persona prompt",
            conversationalOutputPrompt: ""
        )

        #expect(messages == [
            .system("Persona prompt\n\nFeature prompt"),
            .user("Hello"),
        ])
    }

    @Test func insertsPersonaPromptWhenNoSystemPromptExists() {
        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            [.user("Hello")],
            systemPromptMode: .prependPersona,
            personaPrompt: "Persona prompt",
            conversationalOutputPrompt: ""
        )

        #expect(messages == [
            .system("Persona prompt"),
            .user("Hello"),
        ])
    }

    @Test func standalonePromptModeLeavesMessagesUnchanged() {
        let original: [InferenceMessage] = [
            .system("Standalone prompt"),
            .user("Hello"),
        ]

        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            original,
            systemPromptMode: .standalone,
            personaPrompt: "Persona prompt",
            conversationalOutputPrompt: "Conversational output prompt"
        )

        #expect(messages == original)
    }

    @Test func dropsLegacyDefaultSystemPromptWhenApplyingPersona() {
        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            [
                .system(AssistantPersona.legacyDefaultSystemPrompt),
                .user("Hello"),
            ],
            systemPromptMode: .prependPersona,
            personaPrompt: "Persona prompt",
            conversationalOutputPrompt: ""
        )

        #expect(messages == [
            .system("Persona prompt"),
            .user("Hello"),
        ])
    }

    @Test func prependsConversationalOutputPromptToFeatureSystemPrompts() {
        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            [
                .system("Feature prompt"),
                .user("Hello"),
            ],
            systemPromptMode: .prependPersona,
            personaPrompt: "Persona prompt",
            conversationalOutputPrompt: "Conversational output prompt"
        )

        #expect(messages == [
            .system("Persona prompt\n\nConversational output prompt\n\nFeature prompt"),
            .user("Hello"),
        ])
    }

    @Test func assistantPersonaPromptUsesCustomPersonality() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("Clawdia", forKey: SettingsKeys.assistantDisplayName)
        fixture.defaults.set(true, forKey: SettingsKeys.assistantUsesCustomPersonality)
        fixture.defaults.set("Be exact, kind, and lightly funny.", forKey: SettingsKeys.assistantCustomPersonality)

        let prompt = AssistantPersona.personaPrompt(userDefaults: fixture.defaults)

        #expect(prompt.contains("You are Clawdia"))
        #expect(prompt.contains("When the user says \"Clawdia\", they are addressing you."))
        #expect(prompt.contains("# Personality"))
        #expect(prompt.contains("Be exact, kind, and lightly funny."))
    }

    @Test func assistantPersonaPromptAssertsConfiguredUserName() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("Ember", forKey: SettingsKeys.personaDisplayName)

        let prompt = AssistantPersona.personaPrompt(userDefaults: fixture.defaults)

        #expect(prompt.contains("# User"))
        #expect(prompt.contains("The user's name is Ember."))
        #expect(prompt.contains("never switch to a different name for the user"))
    }

    @Test func assistantPersonaPromptAlwaysCarriesAUserSection() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let prompt = AssistantPersona.personaPrompt(userDefaults: fixture.defaults)

        // Without an override the name is host-detected (macOS) or unknown
        // (iOS); either way the section exists and the placeholder never
        // appears as a name.
        #expect(prompt.contains("# User"))
        #expect(!prompt.contains("The user's name is friend."))
    }

    private static func encodedObject(_ query: ChatQuery) throws -> [String: Any] {
        let data = try JSONEncoder().encode(query)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
