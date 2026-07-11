import Foundation
import SwiftData

@MainActor
final class AppBootstrap {
    static let shared = AppBootstrap()

    private static let logger = AppLog.make("app.bootstrap")
    private var hasRun = false

    private init() {}

    func run(modelContainer: ModelContainer) async {
        guard !hasRun else { return }
        guard !Task.isCancelled else { return }
        hasRun = true

        guard !ProcessInfo.processInfo.isRunningInPreview else {
            Self.logger.info("Skipping app bootstrap in preview")
            return
        }

        Keychain.migrateAPIKeysFromUserDefaults()
        EmailAccountStore.shared.migrateLegacyIfNeeded()
        EmailRepository(modelContext: ModelContext(modelContainer))
            .backfillFolderRolesIfNeeded(accounts: EmailAccountStore.shared.accounts)

        // Reconcile the persisted unread-chat set with the store: a chat
        // removed without passing through the router (store reset, migration
        // recovery) must not badge the dock forever.
        if let chats = try? ModelContext(modelContainer).fetch(FetchDescriptor<Chat>()) {
            AppRouter.shared.pruneUnreadChats(keeping: Set(chats.map(\.id)))
        }

        // Drains any notification quick actions that were tapped before the
        // container existed (cold-launch action tap).
        NotificationMailActionHandler.shared.configure(modelContainer: modelContainer)

        EmailWorkflowManager.shared.start(modelContainer: modelContainer)
        if SettingsStorage.isCalendarEnabled() {
            CalendarSyncCoordinator.shared.start(modelContainer: modelContainer)
            CalendarAlertScheduler.shared.start(modelContainer: modelContainer)
            CalendarWorkflowManager.shared.start(modelContainer: modelContainer)
        }
        Self.logger.info("App bootstrap complete")
    }
}
