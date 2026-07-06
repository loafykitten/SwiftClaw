import Foundation
import Observation

/// Publishes mail sync status to the UI ("Syncing mail…", "Synced 2 min.
/// ago · 3 new"). Mirrors `ToolActivityMonitor`.
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
        statusLabel = nil
    }

    /// "Synced 2 min. ago · 3 new · 1 removed" — the sync deltas ride on the
    /// timestamp so they read as per-sync counts. A bare "3 new messages"
    /// status used to linger in the footer where it competed with the unread
    /// badge and read like a mailbox total.
    var lastSyncSummary: String? {
        guard let lastSyncDate else { return nil }
        var parts = ["Synced \(lastSyncDate.formatted(.relative(presentation: .named)))"]
        if lastNewMessageCount > 0 {
            parts.append("\(lastNewMessageCount) new")
        }
        if lastRemovedMessageCount > 0 {
            parts.append("\(lastRemovedMessageCount) removed")
        }
        return parts.joined(separator: " · ")
    }
}
