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
    let description: String
    let systemImage = "tray.and.arrow.down"
    let parameters: [ToolParameter]

    var isConfigured: Bool { true }
    var requiresExplicitEnable: Bool { false }

    private let modelContainer: ModelContainer
    /// Suppression toggle for this pass: the scheduled loop sets true (decay
    /// suppression on); the forced/conversational path sets false so the model
    /// can query the whole inbox by its filters.
    private let applySuppression: Bool
    /// Defaults used when the model omits optional arguments. The model can
    /// still override any of them when the user's message steers a pass.
    private let defaults: EmailReviewFetchDefaults
    /// Reports the thread IDs returned by each fetch call so the service can
    /// stamp exactly what was reviewed (the union across calls in a pass).
    private let onThreadsFetched: (@MainActor ([UUID]) -> Void)?

    init(
        modelContainer: ModelContainer,
        applySuppression: Bool,
        defaults: EmailReviewFetchDefaults,
        onThreadsFetched: (@MainActor ([UUID]) -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.applySuppression = applySuppression
        self.defaults = defaults
        self.onThreadsFetched = onThreadsFetched
        self.description = Self.description(defaults: defaults)
        self.parameters = Self.parameters(defaults: defaults)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        var filter = defaults.filter(applySuppression: applySuppression)
        if let age = Self.intArgument(arguments["max_age_days"]) { filter.maxAgeDays = max(0, age) }
        if let limit = Self.intArgument(arguments["limit"]) { filter.limit = max(1, limit) }
        if let v = Self.boolArgument(arguments["include_flagged"]) { filter.includeFlagged = v }
        if let v = Self.boolArgument(arguments["include_notated"]) { filter.includeNotated = v }
        if let v = Self.boolArgument(arguments["include_read"]) { filter.includeRead = v }
        if let v = Self.boolArgument(arguments["include_unread"]) { filter.includeUnread = v }
        if let v = Self.boolArgument(arguments["include_archived"]) { filter.includeArchived = v }
        if let v = Self.boolArgument(arguments["include_trashed"]) { filter.includeTrashed = v }
        if let folders = Self.stringArrayArgument(arguments["folders"]), !folders.isEmpty {
            filter.folders = folders
        }
        filter.includedCustomFoldersByAccount = await MainActor.run {
            EmailReviewFetchFilter.includedCustomFoldersByAccount(from: EmailAccountStore.shared.accounts)
        }

        let filterToFetch = filter
        let (descriptors, count): ([EmailReviewThreadDescriptor], Int) = await MainActor.run {
            let context = ModelContext(modelContainer)
            let repository = EmailRepository(modelContext: context)
            let threads = repository.fetchThreadsForReview(filter: filterToFetch)
            onThreadsFetched?(threads.map(\.id))
            let descriptors = threads.map { EmailReviewThreadDescriptor.make(for: $0) }
            return (descriptors, threads.count)
        }
        let json = await Task.detached(priority: .utility) {
            Self.encode(descriptors)
        }.value

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

    private static func description(defaults: EmailReviewFetchDefaults) -> String {
        """
        Fetches a filtered slice of the user's inbox threads to review. Call this \
        first, before deciding what needs the user's attention. All parameters are \
        optional; omitted parameters use the user's configured defaults. Omitted \
        `folders` means scheduled-review folders only: INBOX plus any custom folders \
        the user opted into. Pass `folders` with explicit folder names to inspect \
        Junk, Sent, Drafts, Archive, Trash, or custom folders on request. The user's \
        current defaults are: max_age_days \(defaults.maxAgeDescription); \
        limit=\(defaults.limit) (max threads, though unread/flagged/notated \
        threads are always returned even beyond the limit); \
        include_flagged=\(defaults.includeFlagged), include_notated=\(defaults.includeNotated), \
        include_read=\(defaults.includeRead), include_unread=\(defaults.includeUnread), \
        include_archived=\(defaults.includeArchived), include_trashed=\(defaults.includeTrashed). \
        Override these when the user asks for a narrower timeframe, a different limit, \
        or a category like unread, flagged, archived, or trash.
        """
    }

    private static func parameters(defaults: EmailReviewFetchDefaults) -> [ToolParameter] {
        [
            ToolParameter(name: "max_age_days", type: .integer, description: """
            Only include threads whose latest activity is within this many days. \
            Omit to use the user's default: \(defaults.maxAgeDescription). \
            Flagged/notated threads ignore this window.
            """),
            ToolParameter(name: "limit", type: .integer, description: """
            Maximum number of threads to return. Unread, flagged, and notated \
            threads are returned even when there are more of them than the limit. \
            Omit to use the user's configured default: \(defaults.limit). Set a \
            value when the user asks for a specific amount.
            """),
            ToolParameter(name: "include_flagged", type: .boolean, description: "Include flagged threads. Default \(defaults.includeFlagged)."),
            ToolParameter(name: "include_notated", type: .boolean, description: "Include threads the user has written notes on. Default \(defaults.includeNotated)."),
            ToolParameter(name: "include_read", type: .boolean, description: "Include already-read threads. Set false to fetch only unread. Default \(defaults.includeRead)."),
            ToolParameter(name: "include_unread", type: .boolean, description: "Include unread threads. Default \(defaults.includeUnread)."),
            ToolParameter(name: "include_archived", type: .boolean, description: "Include archived threads. Default \(defaults.includeArchived)."),
            ToolParameter(name: "include_trashed", type: .boolean, description: "Include trashed threads. Default \(defaults.includeTrashed)."),
            ToolParameter(name: "folders", type: .array, description: "Explicit folder names to inspect, such as Junk, Sent, Drafts, Archive, Trash, or a custom folder. Omit for the user's configured scheduled-review folders."),
        ]
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

    private static func stringArrayArgument(_ value: JSONValue?) -> [String]? {
        switch value {
        case .array(let values):
            let strings = values.compactMap { item -> String? in
                if case .string(let string) = item {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }
            return strings.filter { !$0.isEmpty }
        case .string(let string):
            return string
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return nil
        }
    }
}
