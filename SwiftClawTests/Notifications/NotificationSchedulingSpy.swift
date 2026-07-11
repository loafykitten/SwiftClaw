import Foundation
import UserNotifications
@testable import SwiftClaw

/// Spy `NotificationScheduling` for notification tests. Never touches
/// `UNUserNotificationCenter.current()` (which requires an app bundle);
/// records every interaction for assertions.
@MainActor
final class NotificationSchedulingSpy: NotificationScheduling {
    var authorizationStatusValue: UNAuthorizationStatus = .authorized
    var requestAuthorizationError: Error?
    var grantAuthorization = true

    private(set) var requestedAuthorizationOptions: [UNAuthorizationOptions] = []
    private(set) var registeredCategories: Set<UNNotificationCategory> = []
    private(set) var installedDelegate: (any UNUserNotificationCenterDelegate)?
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifierBatches: [[String]] = []
    private(set) var removedPendingIdentifierBatches: [[String]] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedAuthorizationOptions.append(options)
        if let requestAuthorizationError {
            throw requestAuthorizationError
        }
        if grantAuthorization {
            authorizationStatusValue = .authorized
        } else {
            authorizationStatusValue = .denied
        }
        return grantAuthorization
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusValue
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        registeredCategories = categories
    }

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        installedDelegate = delegate
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifierBatches.append(identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifierBatches.append(identifiers)
        addedRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        addedRequests
    }
}
