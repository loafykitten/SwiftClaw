import Foundation
import UserNotifications

/// Testability boundary over `UNUserNotificationCenter`.
///
/// `UNUserNotificationCenter.current()` traps in a process without an app
/// bundle (SPM `swift test`, bundle-less tools), so nothing may touch it at
/// type-initialization time: the real center is wrapped LAZILY by
/// `SystemNotificationCenter` and tests inject a spy instead.
@MainActor
protocol NotificationScheduling: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
}

/// Production wrapper. Resolves `UNUserNotificationCenter.current()` on first
/// use — never in `init` — so merely constructing the shared
/// `AppNotificationService` stays safe in test processes.
@MainActor
final class SystemNotificationCenter: NotificationScheduling {
    private var resolvedCenter: UNUserNotificationCenter?

    private var center: UNUserNotificationCenter {
        if let resolvedCenter {
            return resolvedCenter
        }
        let center = UNUserNotificationCenter.current()
        resolvedCenter = center
        return center
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }
}
