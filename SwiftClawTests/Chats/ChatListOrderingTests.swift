import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct ChatListOrderingTests {
    @Test func latestVisibleMessageDateUsesNewestUserOrAssistantMessage() {
        let chat = Chat(
            title: "Thread",
            modelSelection: "test-model",
            updatedAt: Self.date(10)
        )
        chat.messages = [
            ChatMessage(role: .user, content: "Hi", createdAt: Self.date(20), sortIndex: 0),
            ChatMessage(role: .assistant, content: "Hello", createdAt: Self.date(30), sortIndex: 1),
            ChatMessage(role: .system, content: "Hidden", createdAt: Self.date(40), sortIndex: 2)
        ]

        #expect(chat.latestVisibleMessageDate == Self.date(30))
    }

    @Test func listOrderingUsesLatestVisibleMessageDateBeforeUpdatedAt() {
        let staleUpdatedAt = Chat(
            title: "Edited later",
            modelSelection: "test-model",
            updatedAt: Self.date(100)
        )
        staleUpdatedAt.messages = [
            ChatMessage(role: .user, content: "Old message", createdAt: Self.date(20), sortIndex: 0)
        ]

        let newerMessage = Chat(
            title: "Newer message",
            modelSelection: "test-model",
            updatedAt: Self.date(10)
        )
        newerMessage.messages = [
            ChatMessage(role: .assistant, content: "New message", createdAt: Self.date(30), sortIndex: 0)
        ]

        let sorted = ChatListOrdering.sorted([staleUpdatedAt, newerMessage], pinnedFirst: false)

        #expect(sorted.map(\.title) == ["Newer message", "Edited later"])
    }

    @Test func latestVisibleMessageDateCachesAndTracksAppendsAndVisibilityChanges() {
        let chat = Chat(title: "Thread", modelSelection: "test-model", updatedAt: Self.date(10))
        let first = ChatMessage(role: .user, content: "First", createdAt: Self.date(20), sortIndex: 0)
        first.chat = chat
        chat.messages = [first]

        // Pre-existing rows backfill lazily through the ordering accessor.
        #expect(chat.latestVisibleMessageDate == Self.date(20))
        #expect(chat.latestVisibleMessageAt == Self.date(20))

        chat.appendMessage(role: .assistant, content: "Latest")
        let latest = chat.messages.last
        #expect(chat.latestVisibleMessageAt == latest?.createdAt)

        // Visibility changes require an explicit refresh (no observers on
        // @Model stored properties).
        latest?.role = .system
        chat.refreshLatestVisibleMessageAt()
        #expect(chat.latestVisibleMessageAt == Self.date(20))
    }

    @Test func chatWithoutVisibleMessagesContinuesUsingUpdatedAt() {
        let chat = Chat(title: "Empty", modelSelection: "test-model", updatedAt: Self.date(10))

        #expect(chat.latestVisibleMessageDate == Self.date(10))
        #expect(chat.latestVisibleMessageAt == nil)

        chat.updatedAt = Self.date(20)
        #expect(chat.latestVisibleMessageDate == Self.date(20))
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
