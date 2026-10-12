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

    /// When set, `authorizationStatus()` / `add(_:)` suspend until resumed,
    /// so tests can land a settings change while a post is in flight (the
    /// service checks authorization, then adds, across suspension points).
    var suspendsAuthorizationLookups = false
    var suspendsAdds = false
    private var suspendedLookups: [CheckedContinuation<Void, Never>] = []
    private var suspendedAdds: [CheckedContinuation<Void, Never>] = []
    var suspendedLookupCount: Int { suspendedLookups.count }
    var suspendedAddCount: Int { suspendedAdds.count }

    func resumeSuspendedLookups() {
        let lookups = suspendedLookups
        suspendedLookups = []
        lookups.forEach { $0.resume() }
    }

    func resumeSuspendedAdds() {
        let adds = suspendedAdds
        suspendedAdds = []
        adds.forEach { $0.resume() }
    }

    private(set) var authorizationLookupCount = 0

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationLookupCount += 1
        if suspendsAuthorizationLookups {
            await withCheckedContinuation { suspendedLookups.append($0) }
        }
        return authorizationStatusValue
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        registeredCategories = categories
    }

    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        installedDelegate = delegate
    }

    func add(_ request: UNNotificationRequest) async throws {
        if suspendsAdds {
            // Not visible as pending until the add completes.
            await withCheckedContinuation { suspendedAdds.append($0) }
        }
        addedRequests.append(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifierBatches.append(identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifierBatches.append(identifiers)
        addedRequests.removeAll { identifiers.contains($0.identifier) }
    }

    private(set) var pendingRequestsLookupCount = 0

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingRequestsLookupCount += 1
        return addedRequests
    }
}
