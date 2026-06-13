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

    private static func encodedObject(_ query: ChatQuery) throws -> [String: Any] {
        let data = try JSONEncoder().encode(query)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
