import Foundation

/// Pure presentation logic for `NotesHealthSummary` → the compact banner
/// `NotesView` shows when there's something actionable to surface. Kept
/// separate from any view so the "what counts as a problem" decision is
/// directly testable without SwiftUI.
nonisolated enum NotesHealthPresentation {
    struct Banner: Equatable {
        let message: String
        let hasBrokenLinks: Bool
    }

    /// `nil` when nothing actionable is present. Deliberately never treats
    /// `embeddingAvailable == false` as a problem on its own — that's the
    /// expected, healthy state whenever embeddings are intentionally
    /// disabled in Settings, not a failure to surface.
    static func banner(for summary: NotesHealthSummary) -> Banner? {
        var parts: [String] = []

        if summary.brokenLinkCount > 0 {
            parts.append(summary.brokenLinkCount == 1 ? "1 broken link" : "\(summary.brokenLinkCount) broken links")
        }
        if summary.conflictCopyCount > 0 {
            parts.append(summary.conflictCopyCount == 1 ? "1 conflict copy" : "\(summary.conflictCopyCount) conflict copies")
        }
        if !summary.lastIndexFailedPaths.isEmpty {
            let count = summary.lastIndexFailedPaths.count
            parts.append(count == 1 ? "1 note failed to index" : "\(count) notes failed to index")
        }
        if !summary.ftsAvailable {
            parts.append("full-text search unavailable")
        }
        if let indexError = summary.indexError {
            parts.append(indexError)
        }

        guard !parts.isEmpty else { return nil }
        return Banner(message: parts.joined(separator: " · "), hasBrokenLinks: summary.brokenLinkCount > 0)
    }
}
