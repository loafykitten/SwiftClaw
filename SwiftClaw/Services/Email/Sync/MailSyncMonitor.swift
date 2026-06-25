import Foundation
import Observation

/// Publishes mail sync status to the UI ("Syncing mail…", "X new messages",
/// last sync date). Mirrors `ToolActivityMonitor`.
@MainActor
@Observable
final class MailSyncMonitor {
    static let shared = MailSyncMonitor()

    var isSyncing: Bool = false
    var isReviewing: Bool = false
    var statusLabel: String? = nil
    var lastSyncDate: Date? = nil
    var lastNewMessageCount: Int = 0
    var lastRemovedMessageCount: Int = 0

    func setStatus(_ label: String?, syncing: Bool) {
        statusLabel = label
        isSyncing = syncing
    }

    func setReviewing(_ reviewing: Bool) {
        isReviewing = reviewing
        if reviewing {
            isSyncing = true
            statusLabel = "Reviewing inbox…"
        }
    }

    func recordCompleted(newMessageCount: Int, removedCount: Int = 0) {
        lastSyncDate = .now
        lastNewMessageCount = newMessageCount
        lastRemovedMessageCount = removedCount
        isSyncing = false
        var parts: [String] = []
        if newMessageCount > 0 {
            parts.append("\(newMessageCount) new message\(newMessageCount == 1 ? "" : "s")")
        }
        if removedCount > 0 {
            parts.append("\(removedCount) removed by server")
        }
        statusLabel = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
