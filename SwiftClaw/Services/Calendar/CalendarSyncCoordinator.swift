import CoreData
import Foundation
import SwiftData
import os

/// Reacts to CloudKit merges landing in the calendar store. `@Query`-driven
/// UI refreshes on its own; what needs a nudge is identity: a merge can
/// deliver duplicate rows (no unique constraints in the CloudKit
/// configuration), so remote-change notifications trigger a debounced
/// `CalendarRepository.dedupeAfterRemoteMerge()`.
///
/// SwiftData rides Core Data underneath, and CloudKit-backed stores post
/// `NSPersistentStoreRemoteChange` — that's the wake-up signal.
@MainActor
final class CalendarSyncCoordinator {
    static let shared = CalendarSyncCoordinator()

    private static let logger = AppLog.make("calendar.sync")
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
                CalendarSyncCoordinator.shared.scheduleDedupe()
            }
        }
        Self.logger.info("calendar sync coordinator started")
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

    /// Debounced: CloudKit merges arrive in bursts; one dedupe pass at the
    /// end of a burst is enough.
    private func scheduleDedupe() {
        guard let modelContainer else { return }
        pendingDedupe?.cancel()
        pendingDedupe = Task { @MainActor in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            CalendarRepository(modelContext: ModelContext(modelContainer)).dedupeAfterRemoteMerge()
            Self.logger.info("post-merge dedupe pass complete")
        }
    }

    #if DEBUG
    func resetForTesting() {
        stop()
    }
    #endif
}
