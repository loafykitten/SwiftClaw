import Foundation
import OpenAI
import Testing
@testable import SwiftClaw

struct InferenceQueryTests {
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

    @Test func prependsPersonaPromptToFeatureSystemPrompts() {
        let messages = InferenceService.messagesByApplyingSystemPromptMode(
            [
                .system("Feature prompt"),
                .user("Hello"),
            ],
            systemPromptMode: .prependPersona,
            personaPrompt: "Persona prompt"
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
            personaPrompt: "Persona prompt"
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
            personaPrompt: "Persona prompt"
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
            personaPrompt: "Persona prompt"
        )

        #expect(messages == [
            .system("Persona prompt"),
            .user("Hello"),
        ])
    }

    @Test func assistantPersonaPromptUsesCustomPersonality() throws {
        let suiteName = "AssistantPersonaPromptUsesCustomPersonality-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("Clawdia", forKey: SettingsKeys.assistantDisplayName)
        defaults.set(true, forKey: SettingsKeys.assistantUsesCustomPersonality)
        defaults.set("Be exact, kind, and lightly funny.", forKey: SettingsKeys.assistantCustomPersonality)

        let prompt = AssistantPersona.personaPrompt(userDefaults: defaults)

        #expect(prompt.contains("You are Clawdia"))
        #expect(prompt.contains("Be exact, kind, and lightly funny."))
    }

    private static func encodedObject(_ query: ChatQuery) throws -> [String: Any] {
        let data = try JSONEncoder().encode(query)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
