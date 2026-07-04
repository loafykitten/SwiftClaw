import Foundation
@testable import SwiftClaw
import Testing

struct ChatSearchMatchingTests {
    @Test func matchesTitleModelAndVisibleMessages() {
        let chat = Chat(
            title: "Launch Planning",
            modelSelection: "gpt-5-codex"
        )
        chat.messages = [
            ChatMessage(role: .system, content: "Hidden operations note", sortIndex: 0),
            ChatMessage(role: .user, content: "Can you make the checklist calmer?", sortIndex: 1),
            ChatMessage(role: .assistant, content: "Here is a smaller launch plan.", sortIndex: 2),
        ]

        #expect(chat.matchesSearch("launch"))
        #expect(chat.matchesSearch("codex"))
        #expect(chat.matchesSearch("checklist calmer"))
        #expect(!chat.matchesSearch("operations"))
        #expect(!chat.matchesSearch("invoice"))
    }

    @Test func emptyQueryMatchesEverything() {
        let chat = Chat(title: "Anything", modelSelection: "test-model")

        #expect(chat.matchesSearch(""))
        #expect(chat.matchesSearch("   "))
    }
}
