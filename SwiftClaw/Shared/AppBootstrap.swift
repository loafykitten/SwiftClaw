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

        EmailWorkflowManager.shared.start(modelContainer: modelContainer)
        Self.logger.info("App bootstrap complete")
    }
}
