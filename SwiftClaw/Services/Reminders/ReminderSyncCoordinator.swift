import CoreData
import Foundation
import os
import SwiftData

/// Reacts to CloudKit merges landing in the calendar/reminders store.
/// `@Query`-driven UI refreshes on its own; what needs a nudge is identity: a
/// merge can deliver duplicate rows (no unique constraints in the CloudKit
/// configuration), so remote-change notifications trigger a debounced
/// `ReminderRepository.dedupeAfterRemoteMerge()`.
///
/// SwiftData rides Core Data underneath, and CloudKit-backed stores post
/// `NSPersistentStoreRemoteChange` — that's the wake-up signal.
@MainActor
final class ReminderSyncCoordinator {
    static let shared = ReminderSyncCoordinator()

    private static let logger = AppLog.make("reminders.sync")
    private static let debounceInterval: Duration = .seconds(3)

    private var modelContainer: ModelContainer?
    private var observer: (any NSObjectProtocol)?
    private var pendingDedupe: Task<Void, Never>?

    private init() {}

    func start(modelContainer: ModelContainer) {
        guard observer == nil else { return }
        self.modelContainer = modelContainer
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                ReminderSyncCoordinator.shared.scheduleDedupe()
            }
        }
        Self.logger.info("reminder sync coordinator started")
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        pendingDedupe?.cancel()
        pendingDedupe = nil
        modelContainer = nil
    }

    /// Debounced: CloudKit merges arrive in bursts; one dedupe pass at the end
    /// of a burst is enough.
    private func scheduleDedupe() {
        guard let modelContainer else { return }
        pendingDedupe?.cancel()
        pendingDedupe = Task { @MainActor in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            ReminderRepository(modelContext: ModelContext(modelContainer)).dedupeAfterRemoteMerge()
            Self.logger.info("post-merge reminder dedupe pass complete")
        }
    }

    #if DEBUG
        func resetForTesting() {
            stop()
        }
    #endif
}
