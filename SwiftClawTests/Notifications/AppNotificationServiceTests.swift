import Foundation
import Testing
import UserNotifications
@testable import SwiftClaw

/// Exercises the `AppNotificationService` facade against a spy center:
/// activation, authorization options, master/per-source gating, the new-mail
/// digest policy, deterministic identifiers, and delivered-notification
/// removal. Each test builds its own service instance (not `.shared`) so the
/// suite is parallel-safe against every other singleton-touching suite.
@MainActor
struct AppNotificationServiceTests {
    private static func activatedService(
        spy: NotificationSchedulingSpy,
        defaults: UserDefaults,
        authorization: UNAuthorizationStatus = .authorized,
        notificationsEnabled: Bool = true
    ) async -> AppNotificationService {
        defaults.set(notificationsEnabled, forKey: SettingsKeys.notificationsEnabled)
        spy.authorizationStatusValue = authorization
        let service = AppNotificationService()
        service.configureForTesting(center: spy, userDefaults: defaults)
        service.activate()
        await service.refreshAuthorizationStatus()
        return service
    }

    // MARK: - Activation & authorization

    @Test func activateInstallsDelegateAndNewMailCategory() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        #expect(spy.installedDelegate === service)
        #expect(spy.registeredCategories.map(\.identifier) == [NotificationCategoryID.newMail])
        let actions = try #require(spy.registeredCategories.first).actions.map(\.identifier)
        #expect(actions == [
            NotificationActionID.mailArchive,
            NotificationActionID.mailDelete,
            NotificationActionID.mailFlag,
            NotificationActionID.mailReply,
        ])
    }

    @Test func enableNotificationsRequestsAlertAndSoundButNeverBadge() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        spy.authorizationStatusValue = .notDetermined
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .notDetermined
        )

        let granted = await service.enableNotifications()

        #expect(granted)
        let options = try #require(spy.requestedAuthorizationOptions.first)
        #expect(options.contains(.alert))
        #expect(options.contains(.sound))
        #expect(!options.contains(.badge), "the dock badge belongs to AppRouter")
        #expect(service.authorizationStatus == .authorized)
    }

    @Test func enableNotificationsReportsDenial() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        spy.grantAuthorization = false
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .notDetermined
        )

        let granted = await service.enableNotifications()

        #expect(!granted)
        #expect(service.authorizationStatus == .denied)
    }

    // MARK: - Launch prompt

    @Test func launchPromptIsOfferedOnlyWhileUndeterminedAndUnanswered() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .notDetermined,
            notificationsEnabled: false
        )

        #expect(await service.shouldOfferLaunchPrompt())

        // Answering (either way) retires the offer for good.
        service.declineLaunchPrompt()
        #expect(await service.shouldOfferLaunchPrompt() == false)
    }

    @Test func launchPromptIsNotOfferedOnceTheSystemStatusIsDetermined() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .authorized,
            notificationsEnabled: false
        )

        // Already authorized/denied (e.g. the user enabled via Settings
        // first): the system dialog has run, so the offer is moot.
        #expect(await service.shouldOfferLaunchPrompt() == false)

        spy.authorizationStatusValue = .denied
        #expect(await service.shouldOfferLaunchPrompt() == false)
    }

    @Test func acceptingTheLaunchPromptEnablesTheMasterToggleAndRequestsAuthorization() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .notDetermined,
            notificationsEnabled: false
        )

        await service.acceptLaunchPrompt()

        #expect(SettingsStorage.areNotificationsEnabled(userDefaults: fixture.defaults))
        #expect(spy.requestedAuthorizationOptions.count == 1)
        #expect(service.authorizationStatus == .authorized)
        #expect(await service.shouldOfferLaunchPrompt() == false)
    }

    @Test func decliningTheLaunchPromptLeavesTheSystemStatusUntouched() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .notDetermined,
            notificationsEnabled: false
        )

        service.declineLaunchPrompt()

        // No system request was made, so Settings can still raise the real
        // authorization dialog later.
        #expect(spy.requestedAuthorizationOptions.isEmpty)
        #expect(!SettingsStorage.areNotificationsEnabled(userDefaults: fixture.defaults))
        let granted = await service.enableNotifications()
        #expect(granted)
        #expect(spy.requestedAuthorizationOptions.count == 1)
    }

    // MARK: - Gating

    @Test func postsNothingBeforeActivation() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsEnabled)
        let spy = NotificationSchedulingSpy()
        let service = AppNotificationService()
        service.configureForTesting(center: spy, userDefaults: fixture.defaults)

        // Configured but never activated: every post must be a no-op.
        service.notifyChatReply(chatID: UUID(), chatTitle: "Chat", preview: "Hi")
        service.notifyReviewResult(chatID: UUID(), summary: "Summary")
        service.notifyNewMail([Self.mailInfo()])
        service.notifyResearchComplete(sessionID: UUID(), title: "Research", isPartial: false)
        await service.flushPostsForTesting()

        #expect(spy.addedRequests.isEmpty)
    }

    @Test func masterToggleOffSuppressesEverySource() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            notificationsEnabled: false
        )
        // Per-source keys explicitly on — the master must still gate them.
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsNewMailEnabled)
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsReviewResultsEnabled)
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsChatRepliesEnabled)
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsResearchCompleteEnabled)

        service.notifyChatReply(chatID: UUID(), chatTitle: "Chat", preview: "Hi")
        service.notifyReviewResult(chatID: UUID(), summary: "Summary")
        service.notifyNewMail([Self.mailInfo()])
        service.notifyResearchComplete(sessionID: UUID(), title: "Research", isPartial: false)
        await service.flushPostsForTesting()

        #expect(spy.addedRequests.isEmpty)
    }

    @Test func postsReadAuthorizationFreshInsteadOfTrustingTheLaunchCache() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: SettingsKeys.notificationsEnabled)
        let spy = NotificationSchedulingSpy()
        spy.authorizationStatusValue = .authorized
        let service = AppNotificationService()
        service.configureForTesting(center: spy, userDefaults: fixture.defaults)

        // Launch race: post immediately after activate(), before its
        // fire-and-forget status refresh could land. The system is already
        // authorized, so the notification must not be dropped.
        service.activate()
        service.notifyChatReply(chatID: UUID(), chatTitle: "Chat", preview: "Hi")
        await service.flushPostsForTesting()

        #expect(spy.addedRequests.count == 1)
    }

    @Test func deniedAuthorizationSuppressesEverySource() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(
            spy: spy,
            defaults: fixture.defaults,
            authorization: .denied
        )

        service.notifyChatReply(chatID: UUID(), chatTitle: "Chat", preview: "Hi")
        service.notifyNewMail([Self.mailInfo()])
        await service.flushPostsForTesting()

        #expect(spy.addedRequests.isEmpty)
    }

    @Test func perSourceTogglesGateIndependently() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)
        fixture.defaults.set(false, forKey: SettingsKeys.notificationsChatRepliesEnabled)
        fixture.defaults.set(false, forKey: SettingsKeys.notificationsNewMailEnabled)
        fixture.defaults.set(false, forKey: SettingsKeys.notificationsResearchCompleteEnabled)

        service.notifyChatReply(chatID: UUID(), chatTitle: "Chat", preview: "Hi")
        service.notifyNewMail([Self.mailInfo()])
        service.notifyResearchComplete(sessionID: UUID(), title: "Research", isPartial: false)
        let reviewChatID = UUID()
        service.notifyReviewResult(chatID: reviewChatID, summary: "Summary")
        await service.flushPostsForTesting()

        // Only the still-enabled review source posts.
        #expect(spy.addedRequests.map(\.identifier) == [NotificationIdentifier.review(reviewChatID)])
    }

    // MARK: - Content & identifiers

    @Test func chatReplyUsesDeterministicIdentifierAndTruncatedPreview() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let chatID = UUID()
        let longReply = String(repeating: "x", count: 500)
        service.notifyChatReply(chatID: chatID, chatTitle: "Trip planning", preview: longReply)
        await service.flushPostsForTesting()

        let request = try #require(spy.addedRequests.first)
        #expect(request.identifier == "chatreply.\(chatID.uuidString)")
        #expect(request.content.title == "Trip planning")
        #expect(request.content.body.count == AppNotificationService.chatReplyPreviewLimit)
        #expect(request.content.badge == nil, "notification content must never set the badge")
        let payload = NotificationRoutingPayload(userInfo: request.content.userInfo)
        #expect(payload == NotificationRoutingPayload(kind: .chatReply, targetID: chatID))
    }

    @Test func reviewSummaryBodyIsCappedWithAnEllipsis() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let longSummary = String(repeating: "a", count: 400)
        service.notifyReviewResult(chatID: UUID(), summary: longSummary)
        service.notifyReviewResult(chatID: UUID(), summary: "Short.")
        await service.flushPostsForTesting()

        let capped = try #require(spy.addedRequests.first?.content.body)
        #expect(capped.count == AppNotificationService.reviewSummaryLimit)
        #expect(capped.hasSuffix("…"))
        #expect(spy.addedRequests.last?.content.body == "Short.")
    }

    @Test func routingPayloadRoundTripsThroughUserInfo() {
        for kind in [NotificationRoutingPayload.Kind.chatReply, .review, .newMail, .mailDigest, .calendarEvent, .reminder, .research] {
            let payload = NotificationRoutingPayload(kind: kind, targetID: UUID())
            #expect(NotificationRoutingPayload(userInfo: payload.userInfo) == payload)
        }
        #expect(NotificationRoutingPayload(userInfo: [:]) == nil)
        #expect(NotificationRoutingPayload(userInfo: ["swiftclaw.notification.kind": "bogus"]) == nil)
    }

    @Test func researchCompletionUsesDeterministicContentAndRouting() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)
        let sessionID = UUID()

        service.notifyResearchComplete(
            sessionID: sessionID,
            title: "Durable topic",
            isPartial: true
        )
        await service.flushPostsForTesting()

        let request = try #require(spy.addedRequests.first)
        #expect(request.identifier == NotificationIdentifier.research(sessionID))
        #expect(request.content.title == "Research finished with partial results")
        #expect(request.content.body == "Durable topic")
        #expect(request.content.threadIdentifier == "research.\(sessionID.uuidString)")
        #expect(
            NotificationRoutingPayload(userInfo: request.content.userInfo)
                == NotificationRoutingPayload(kind: .research, targetID: sessionID)
        )
    }

    // MARK: - Digest policy

    @Test func fewNewMailMessagesPostIndividuallyWithActions() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let accountID = UUID()
        let messages = (0..<AppNotificationService.maxIndividualMailNotifications).map { _ in
            Self.mailInfo(accountID: accountID)
        }
        service.notifyNewMail(messages)
        await service.flushPostsForTesting()

        #expect(spy.addedRequests.count == messages.count)
        for request in spy.addedRequests {
            #expect(request.content.categoryIdentifier == NotificationCategoryID.newMail)
            #expect(request.identifier.hasPrefix("mail."))
            #expect(!request.identifier.hasPrefix("mail.digest."))
        }
    }

    @Test func manyNewMailMessagesCollapseIntoOneDigestWithoutActions() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let accountID = UUID()
        let count = AppNotificationService.maxIndividualMailNotifications + 1
        service.notifyNewMail((0..<count).map { _ in Self.mailInfo(accountID: accountID) })
        await service.flushPostsForTesting()

        let request = try #require(spy.addedRequests.first)
        #expect(spy.addedRequests.count == 1)
        #expect(request.identifier == NotificationIdentifier.mailDigest(accountID))
        #expect(request.content.categoryIdentifier.isEmpty, "digests carry no quick actions")
        #expect(request.content.body == "\(count) new messages")
        let payload = NotificationRoutingPayload(userInfo: request.content.userInfo)
        #expect(payload == NotificationRoutingPayload(kind: .mailDigest, targetID: accountID))
    }

    @Test func digestPolicyAppliesPerAccount() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let quietAccount = UUID()
        let busyAccount = UUID()
        var messages = [Self.mailInfo(accountID: quietAccount)]
        messages += (0...AppNotificationService.maxIndividualMailNotifications).map { _ in
            Self.mailInfo(accountID: busyAccount)
        }
        service.notifyNewMail(messages)
        await service.flushPostsForTesting()

        // One individual notification for the quiet account, one digest for
        // the busy one.
        #expect(spy.addedRequests.count == 2)
        let identifiers = spy.addedRequests.map(\.identifier)
        #expect(identifiers.contains(NotificationIdentifier.mailDigest(busyAccount)))
        #expect(!identifiers.contains(NotificationIdentifier.mailDigest(quietAccount)))
    }

    // MARK: - Removal

    @Test func removalUsesTheDeterministicIdentifiers() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let spy = NotificationSchedulingSpy()
        let service = await Self.activatedService(spy: spy, defaults: fixture.defaults)

        let chatID = UUID()
        let emailID = UUID()
        let accountID = UUID()
        service.removeDeliveredChatNotifications(chatID: chatID)
        service.removeDeliveredEmailNotification(emailID: emailID)
        service.removeDeliveredEmailNotification(emailID: emailID, accountID: accountID)

        #expect(spy.removedIdentifierBatches == [
            ["chatreply.\(chatID.uuidString)", "review.\(chatID.uuidString)"],
            ["mail.\(emailID.uuidString)"],
            // Reading mail in-app also retires the account's stale digest.
            ["mail.\(emailID.uuidString)", "mail.digest.\(accountID.uuidString)"],
        ])
    }

    @Test func removalIsANoOpBeforeActivation() throws {
        let service = AppNotificationService()
        // No center configured at all — must not trap or touch the real
        // notification center.
        service.removeDeliveredChatNotifications(chatID: UUID())
        service.removeDeliveredEmailNotification(emailID: UUID())
    }

    // MARK: - Helpers

    private static func mailInfo(accountID: UUID = UUID()) -> NewMailNotificationInfo {
        NewMailNotificationInfo(
            emailID: UUID(),
            accountID: accountID,
            fromDisplay: "Sender",
            subject: "Subject",
            snippet: "Snippet"
        )
    }
}
