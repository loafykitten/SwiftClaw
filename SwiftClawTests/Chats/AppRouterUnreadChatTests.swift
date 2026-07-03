import Foundation
import Testing
@testable import SwiftClaw

@MainActor
@Suite(.serialized)
struct AppRouterUnreadChatTests {
    @Test func newMessagesMarkThreadUnreadWhenItIsNotOpen() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        let chatID = UUID()
        router.selectedNavigationItem = .workspace

        router.noteNewChatMessages(in: chatID)

        #expect(router.hasUnreadChats)
        #expect(router.hasUnreadMessages(in: chatID))
    }

    @Test func newMessagesDoNotMarkThreadUnreadWhenItIsOpen() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        let chatID = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID

        router.noteNewChatMessages(in: chatID)

        #expect(router.hasUnreadChats == false)
        #expect(router.hasUnreadMessages(in: chatID) == false)
    }

    @Test func openingUnreadThreadClearsOnlyThatThread() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        let firstChatID = UUID()
        let secondChatID = UUID()
        router.noteNewChatMessages(in: firstChatID)
        router.noteNewChatMessages(in: secondChatID)

        router.selectedNavigationItem = .chats
        router.selectedChatID = firstChatID
        router.clearUnreadChatIfOpened()

        #expect(router.hasUnreadMessages(in: firstChatID) == false)
        #expect(router.hasUnreadMessages(in: secondChatID))
        #expect(router.hasUnreadChats)
    }

    @Test func clearingUnreadThreadRemovesTopLevelUnreadState() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        let chatID = UUID()
        router.noteNewChatMessages(in: chatID)

        let didClear = router.clearUnreadMessages(in: chatID)

        #expect(didClear)
        #expect(router.hasUnreadMessages(in: chatID) == false)
        #expect(router.hasUnreadChats == false)
    }

    @Test func openingSettingsStoresRequestedSection() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        router.openSettings(section: .persona)

        #expect(router.pendingSettingsSection == .persona)
    }
}
