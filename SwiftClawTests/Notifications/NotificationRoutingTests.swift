import Foundation
import Testing
@testable import SwiftClaw

/// Delegate-routing behavior: notification taps navigate through `AppRouter`,
/// and `willPresent` suppression hides banners for the content the user is
/// already looking at. Serialized — mutates the shared router.
@MainActor
@Suite(.serialized)
struct NotificationRoutingTests {
    // MARK: - Tap navigation

    @Test func chatReplyTapSelectsTheChat() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        AppNotificationService.shared.routeNotificationTap(
            payload: NotificationRoutingPayload(kind: .chatReply, targetID: chatID)
        )

        #expect(router.selectedNavigationItem == .chats)
        #expect(router.selectedChatID == chatID)
    }

    @Test func reviewTapSelectsTheReviewChat() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        AppNotificationService.shared.routeNotificationTap(
            payload: NotificationRoutingPayload(kind: .review, targetID: chatID)
        )

        #expect(router.selectedNavigationItem == .chats)
        #expect(router.selectedChatID == chatID)
    }

    @Test func newMailTapShowsTheEmail() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let emailID = UUID()
        AppNotificationService.shared.routeNotificationTap(
            payload: NotificationRoutingPayload(kind: .newMail, targetID: emailID)
        )

        #expect(router.selectedNavigationItem == .workspace)
        #expect(router.pendingEmailViewID == emailID)
    }

    @Test func digestTapSelectsTheWorkspace() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        AppNotificationService.shared.routeNotificationTap(
            payload: NotificationRoutingPayload(kind: .mailDigest, targetID: UUID())
        )

        #expect(router.selectedNavigationItem == .workspace)
        #expect(router.pendingEmailViewID == nil)
    }

    @Test func reminderTapShowsRemindersWithTheFocusID() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let reminderID = UUID()
        AppNotificationService.shared.routeNotificationTap(
            payload: NotificationRoutingPayload(kind: .reminder, targetID: reminderID)
        )

        #expect(router.selectedNavigationItem == .workspace)
        #expect(router.pendingReminderFocusID == reminderID)
    }

    @Test func undecodablePayloadRoutesNowhere() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        AppNotificationService.shared.routeNotificationTap(payload: nil)

        #expect(router.selectedNavigationItem == .home)
    }

    // MARK: - willPresent suppression

    @Test func chatReplyBannerIsSuppressedOnlyWhileViewingThatChat() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let chatID = UUID()
        let payload = NotificationRoutingPayload(kind: .chatReply, targetID: chatID)

        router.selectedNavigationItem = .chats
        router.selectedChatID = chatID
        #expect(AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))

        router.selectedChatID = UUID()
        #expect(!AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))

        router.selectedChatID = chatID
        router.selectedNavigationItem = .workspace
        #expect(!AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))
    }

    @Test func mailBannerIsSuppressedWhileTheWorkspaceIsSelected() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let payload = NotificationRoutingPayload(kind: .newMail, targetID: UUID())

        router.selectedNavigationItem = .workspace
        #expect(AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))

        router.selectedNavigationItem = .home
        #expect(!AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))
    }

    @Test func reminderBannerIsNeverSuppressed() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        let payload = NotificationRoutingPayload(kind: .reminder, targetID: UUID())

        // Time-critical: shown even while the user is in Workspace.
        router.selectedNavigationItem = .workspace
        #expect(!AppNotificationService.shouldSuppressPresentation(payload: payload, router: router))
    }

    @Test func missingPayloadNeverSuppresses() throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }

        #expect(!AppNotificationService.shouldSuppressPresentation(payload: nil, router: router))
    }

    // MARK: - Unread-clear removal hook

    @Test func clearingUnreadMessagesRemovesDeliveredChatNotifications() async throws {
        let (router, fixture) = try Self.isolatedRouter()
        defer { Self.restore(router, fixture) }
        let spy = NotificationSchedulingSpy()
        let service = AppNotificationService.shared
        service.configureForTesting(center: spy, userDefaults: fixture.defaults)
        service.activate()
        defer { service.resetForTesting() }

        let chatID = UUID()
        router.selectedNavigationItem = .workspace
        router.noteNewChatMessages(in: chatID)
        router.clearUnreadMessages(in: chatID)

        #expect(spy.removedIdentifierBatches.contains([
            NotificationIdentifier.chatReply(chatID),
            NotificationIdentifier.review(chatID),
        ]))
    }

    // MARK: - Helpers

    private static func isolatedRouter() throws -> (AppRouter, UserDefaultsFixture) {
        let fixture = try UserDefaultsFixture()
        let router = AppRouter.shared
        router.resetForTesting(unreadStore: fixture.defaults)
        return (router, fixture)
    }

    private static func restore(_ router: AppRouter, _ fixture: UserDefaultsFixture) {
        router.resetForTesting()
        fixture.cleanup()
    }
}
