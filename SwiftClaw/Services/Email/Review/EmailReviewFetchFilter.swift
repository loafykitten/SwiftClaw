import Foundation

/// Selection criteria the model passes to `fetch_inbox_emails` to pull the
/// slice of inbox it wants to review. `EmailReviewFetchTool` fills missing
/// arguments with the autonomous-review defaults before handing the filter to
/// `EmailRepository.fetchThreadsForReview`.
nonisolated struct EmailReviewFetchFilter: Sendable {
    /// Lookback window (in days) on a thread's latest activity. Threads older
    /// than this are dropped unless they qualify via an override category
    /// (flagged/notated). Default is no hard age cap; the model narrows this
    /// when steered toward recent mail.
    var maxAgeDays: Int = Int.max

    /// Maximum number of threads to return. Read threads beyond this are
    /// dropped; unread/flagged/notated threads override the cap (see
    /// `fetchThreadsForReview`). Defaults to the configured review max.
    var limit: Int = SettingsStorage.defaultEmailReviewMaxThreads

    var includeFlagged: Bool = true
    var includeNotated: Bool = true
    var includeRead: Bool = true
    var includeUnread: Bool = true
    var includeArchived: Bool = false
    var includeTrashed: Bool = false

    /// When true (the scheduled loop), apply the `lastReviewedAt` /
    /// `reviewedCount` decay suppression so a just-reviewed thread isn't
    /// re-surfaced until its window elapses. The forced/conversational path
    /// sets this false so the model can query the whole inbox by its filters.
    var applySuppression: Bool = true
}
