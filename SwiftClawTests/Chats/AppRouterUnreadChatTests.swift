import Foundation
import Testing
@testable import SwiftClaw

@MainActor
@Suite(.serialized)
struct AppRouterUnreadChatTests {
    @Test func newMessagesMarkThreadUnreadWhenItIsNotOpen() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        router.selectedNavigationItem = .workspace

        router.noteNewChatMessages(in: chatID)

        #expect(router.hasUnreadChats)
        #expect(router.hasUnreadMessages(in: chatID))
    }

    @Test func newMessagesDoNotMarkThreadUnreadWhenItIsOpen() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID

        router.noteNewChatMessages(in: chatID)

        #expect(router.hasUnreadChats == false)
        #expect(router.hasUnreadMessages(in: chatID) == false)
    }

    @Test func openingUnreadThreadClearsOnlyThatThread() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

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

    @Test func clearingUnreadThreadRemovesTopLevelUnreadState() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        router.noteNewChatMessages(in: chatID)

        let didClear = router.clearUnreadMessages(in: chatID)

        #expect(didClear)
        #expect(router.hasUnreadMessages(in: chatID) == false)
        #expect(router.hasUnreadChats == false)
    }

    @Test func unreadStatePersistsToTheInjectedStore() throws {
        // The unread set must survive an app relaunch: mutations write
        // through to the store `AppRouter` was pointed at, in the same
        // format `SettingsStorage.loadUnreadChatIDs` reads back at init.
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        router.noteNewChatMessages(in: chatID)

        #expect(SettingsStorage.loadUnreadChatIDs(userDefaults: fixture.defaults) == [chatID])

        router.clearUnreadMessages(in: chatID)

        #expect(SettingsStorage.loadUnreadChatIDs(userDefaults: fixture.defaults).isEmpty)
    }

    @Test func pruningDropsUnreadIDsForMissingChats() throws {
        // Bootstrap reconciliation: an unread ID whose chat no longer exists
        // (store reset, deletion that bypassed the router) must be dropped
        // from memory AND the persisted set, or it badges the dock forever.
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let survivingID = UUID()
        let staleID = UUID()
        router.noteNewChatMessages(in: survivingID)
        router.noteNewChatMessages(in: staleID)

        router.pruneUnreadChats(keeping: [survivingID])

        #expect(router.hasUnreadMessages(in: survivingID))
        #expect(router.hasUnreadMessages(in: staleID) == false)
        #expect(SettingsStorage.loadUnreadChatIDs(userDefaults: fixture.defaults) == [survivingID])
    }

    @Test func repliesToTheSelectedChatCountAsUnreadWhileTheSceneIsInactive() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        let sceneID = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID
        router.sceneActivityDidChange(true, sceneID: sceneID)
        #expect(router.isViewingChat(chatID))

        router.sceneActivityDidChange(false, sceneID: sceneID)
        router.noteNewChatMessages(in: chatID)

        #expect(router.isViewingChat(chatID) == false)
        #expect(router.hasUnreadMessages(in: chatID))
    }

    @Test func reactivatingTheSceneClearsTheSelectedChatsUnreadState() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        let sceneID = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID
        router.sceneActivityDidChange(false, sceneID: sceneID)
        router.noteNewChatMessages(in: chatID)
        #expect(router.hasUnreadMessages(in: chatID))

        router.sceneActivityDidChange(true, sceneID: sceneID)

        #expect(router.hasUnreadMessages(in: chatID) == false)
    }

    @Test func anyActiveWindowKeepsTheSelectedChatViewed() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        let activeScene = UUID()
        let backgroundScene = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID
        router.sceneActivityDidChange(true, sceneID: activeScene)
        router.sceneActivityDidChange(false, sceneID: backgroundScene)

        #expect(router.isViewingChat(chatID))

        router.sceneActivityDidChange(false, sceneID: activeScene)
        #expect(router.isViewingChat(chatID) == false)
    }

    @Test func liveSceneReportsAreIgnoredOnceTestsResetTheRouter() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID
        router.reportSceneActivity(false, sceneID: UUID())

        #expect(router.isViewingChat(chatID))
    }

    @Test func openingSettingsStoresRequestedSection() {
        let router = AppRouter.shared
        router.resetForTesting()
        defer { router.resetForTesting() }

        router.openSettings(section: .persona)

        #expect(router.pendingSettingsSection == .persona)
    }

    // MARK: - Helpers

    /// Resets the shared router against an isolated `UserDefaults` fixture.
    /// Tests are app-hosted, so `.standard` is the developer's real defaults
    /// — any test that marks chats unread must persist into a fixture.
    private static func isolatedRouter() throws -> (AppRouter, UserDefaultsFixture) {
        let fixture = try UserDefaultsFixture()
        let router = AppRouter.shared
        router.resetForTesting(unreadStore: fixture.defaults)
        return (router, fixture)
    }

    /// Points the router back at `.standard` (without persisting the cleared
    /// set) and tears down the fixture suite.
    private static func restore(_ router: AppRouter, _ fixture: UserDefaultsFixture) {
        router.resetForTesting()
        fixture.cleanup()
    }
}
