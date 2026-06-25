import Foundation
import SwiftData
import os

/// System-only tool that lets the review model pull exactly the slice of inbox
/// it wants to triage, rather than having every eligible thread pushed into the
/// prompt up front. NOT registered on `ToolRegistry.shared` — like
/// `EmailReviewNotifyTool` it's constructed into a one-off registry by
/// `EmailReviewService` for the duration of a single review pass.
///
/// Returns the selected threads as JSON (the same `EmailReviewThreadDescriptor`
/// payload that used to be inlined). The model is expected to call this first,
/// review the result, then call `notify_user_about_emails`.
final class EmailReviewFetchTool: Tool {
    private static let logger = AppLog.make("mail.review.fetch")

    let name = "fetch_inbox_emails"
    let displayName = "Fetch Inbox Emails"
    let description = """
    Fetches a filtered slice of the user's inbox threads to review. Call this \
    first, before deciding what needs the user's attention. All parameters are \
    optional; the defaults select review-eligible inbox mail without a hard age \
    cap so old read backlog can resurface. \
    Defaults: max_age_days omitted (no hard age cap — set it to focus on recent \
    mail); limit=\(SettingsStorage.loadEmailReviewMaxThreads()) \
    (max threads, though unread/flagged/notated threads are always returned even \
    beyond the limit); include_flagged=true, include_notated=true, \
    include_read=true, include_unread=true; include_archived=false, \
    include_trashed=false (exclude archived and trashed mail unless the user \
    asks about it). Set include_read=false to fetch only unread, or narrow the \
    include flags to focus on a category (e.g. only flagged).
    """
    let systemImage = "tray.and.arrow.down"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "max_age_days", type: .integer, description: """
        Only include threads whose latest activity is within this many days. \
        Omit for no hard age cap. Flagged/notated threads ignore this window.
        """),
        ToolParameter(name: "limit", type: .integer, description: """
        Maximum number of threads to return. Unread, flagged, and notated \
        threads are returned even when there are more of them than the limit. \
        Default is the user's configured review maximum.
        """),
        ToolParameter(name: "include_flagged", type: .boolean, description: "Include flagged threads. Default true."),
        ToolParameter(name: "include_notated", type: .boolean, description: "Include threads the user has written notes on. Default true."),
        ToolParameter(name: "include_read", type: .boolean, description: "Include already-read threads. Set false to fetch only unread. Default true."),
        ToolParameter(name: "include_unread", type: .boolean, description: "Include unread threads. Default true."),
        ToolParameter(name: "include_archived", type: .boolean, description: "Include archived threads. Default false."),
        ToolParameter(name: "include_trashed", type: .boolean, description: "Include trashed threads. Default false."),
    ]

    var isConfigured: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let modelContainer: ModelContainer
    /// Suppression toggle for this pass: the scheduled loop sets true (decay
    /// suppression on); the forced/conversational path sets false so the model
    /// can query the whole inbox by its filters.
    private let applySuppression: Bool
    /// Default `limit` when the model omits the argument — the user's
    /// configured review maximum.
    private let defaultLimit: Int
    /// Reports the thread IDs returned by each fetch call so the service can
    /// stamp exactly what was reviewed (the union across calls in a pass).
    private let onThreadsFetched: (@MainActor ([UUID]) -> Void)?

    init(
        modelContainer: ModelContainer,
        applySuppression: Bool,
        defaultLimit: Int,
        onThreadsFetched: (@MainActor ([UUID]) -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.applySuppression = applySuppression
        self.defaultLimit = defaultLimit
        self.onThreadsFetched = onThreadsFetched
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        var filter = EmailReviewFetchFilter(applySuppression: applySuppression)
        filter.limit = defaultLimit
        if let age = Self.intArgument(arguments["max_age_days"]) { filter.maxAgeDays = max(0, age) }
        if let limit = Self.intArgument(arguments["limit"]) { filter.limit = max(1, limit) }
        if let v = Self.boolArgument(arguments["include_flagged"]) { filter.includeFlagged = v }
        if let v = Self.boolArgument(arguments["include_notated"]) { filter.includeNotated = v }
        if let v = Self.boolArgument(arguments["include_read"]) { filter.includeRead = v }
        if let v = Self.boolArgument(arguments["include_unread"]) { filter.includeUnread = v }
        if let v = Self.boolArgument(arguments["include_archived"]) { filter.includeArchived = v }
        if let v = Self.boolArgument(arguments["include_trashed"]) { filter.includeTrashed = v }

        let (json, count): (String, Int) = await MainActor.run {
            let context = ModelContext(modelContainer)
            let repository = EmailRepository(modelContext: context)
            let threads = repository.fetchThreadsForReview(filter: filter)
            onThreadsFetched?(threads.map(\.id))
            let descriptors = threads.map { EmailReviewThreadDescriptor.make(for: $0) }
            return (Self.encode(descriptors), threads.count)
        }

        Self.logger.info("""
            fetch_inbox_emails returned \(count, privacy: .public) thread(s) \
            (suppression: \(self.applySuppression, privacy: .public))
            """)

        if count == 0 {
            return "No inbox threads matched those filters. There may be nothing to review, or try omitting/widening max_age_days or changing the include flags."
        }
        return """
        \(count) thread\(count == 1 ? "" : "s") (JSON). Review these and call notify_user_about_emails for any that need the user.

        \(json)
        """
    }

    private static func encode(_ descriptors: [EmailReviewThreadDescriptor]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(descriptors)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Lenient integer read: accepts a JSON number or a numeric string (some
    /// OpenAI-compatible proxies stringify tool arguments).
    private static func intArgument(_ value: JSONValue?) -> Int? {
        switch value {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Lenient bool read: accepts a JSON bool or a "true"/"false" string.
    private static func boolArgument(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }
}
