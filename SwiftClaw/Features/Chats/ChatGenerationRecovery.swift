import Foundation
import SwiftData

/// Clears `Chat.isGenerating` flags orphaned by a quit, crash, or force-kill
/// mid-completion. The flag is persisted before inference starts, and no
/// completion task survives a relaunch — without this pass the composer
/// stays disabled forever with nothing left to clear it.
@MainActor
enum ChatGenerationRecovery {
    static let interruptedMessage =
        "The reply was interrupted before it finished. Send your message again to retry."

    /// Returns the number of chats recovered. `hasLiveCompletion` lets a
    /// completion started before this pass runs keep its flag.
    @discardableResult
    static func recoverInterruptedGenerations(
        in modelContext: ModelContext,
        hasLiveCompletion: (UUID) -> Bool = { ChatTaskCoordinator.shared.hasActiveCompletion(for: $0) }
    ) -> Int {
        let descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.isGenerating })
        guard let generating = try? modelContext.fetch(descriptor) else { return 0 }

        let interrupted = generating.filter { !hasLiveCompletion($0.id) }
        guard !interrupted.isEmpty else { return 0 }

        for chat in interrupted {
            chat.isGenerating = false
            chat.errorMessage = interruptedMessage
        }
        try? modelContext.save()
        return interrupted.count
    }
}
