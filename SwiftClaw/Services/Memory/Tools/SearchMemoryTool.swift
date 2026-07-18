import Foundation

/// Lexical search over memory entry bodies, tags, and collection titles —
/// the tool-facing face of `MemoryRepository.search`, the same seam the
/// Memory UI uses. Lives on `ToolRegistry.shared` (reads are always
/// allowed) and vanishes from every chat the moment Memory is disabled.
///
/// In the full-injection tier this is a convenience; in the index tier it is
/// the expansion mechanism the compact index points at — a second chance,
/// never the only chance.
struct SearchMemoryTool: Tool {
    static let defaultLimit = 15
    static let maxLimit = 40

    /// Seam so gating/search can be exercised with stubs in tests instead
    /// of the live `MemoryFeatureModel` singleton (`SearchNotesTool`
    /// precedent).
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
        var search: @MainActor @Sendable (_ query: String, _ limit: Int) -> [MemorySearchHit]

        static let live = Dependencies(
            isAvailable: { MemoryFeatureModel.shared.isAvailable },
            search: { query, limit in
                guard let repository = MemoryFeatureModel.shared.repository else { return [] }
                return repository.search(query, limit: limit).map(MemorySearchHit.init)
            }
        )
    }

    /// Sendable snapshot of a matched entry — `MemoryEntry` is a SwiftData
    /// model and must not cross the tool's nonisolated boundary.
    struct MemorySearchHit: Sendable {
        let handle: String
        let body: String
        let collectionTitle: String?
        let isSuperseded: Bool

        @MainActor
        init(entry: MemoryEntry) {
            handle = entry.handle
            body = entry.body
            collectionTitle = entry.collection?.title
            isSuperseded = entry.supersededByID != nil
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    let name = "search_memory"
    let displayName = "Search Memory"
    let description = """
        Search the persistent memory store (entry text, tags, and collection \
        titles). Returns matching entries with their 8-character handles. \
        Prefer over-searching to missing a stored fact; use \
        open_memory_collection to read a whole collection.
        """
    let systemImage = "brain"

    let parameters = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "Search terms; every term must match somewhere.",
            isRequired: true
        ),
        ToolParameter(
            name: "limit",
            type: .integer,
            description: "Number of entries to return (1-40, default 15)."
        ),
    ]

    /// `MainActor.assumeIsolated` is safe here: both call sites that read
    /// `Tool.isConfigured` (`ChatCompletionService`, `ToolsView`) are
    /// themselves `@MainActor`.
    var isConfigured: Bool {
        MainActor.assumeIsolated {
            dependencies.isAvailable()
        }
    }

    static let unavailableReason = "Memory is disabled in Settings."

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard await dependencies.isAvailable() else {
            throw ToolError.notConfigured(toolName: displayName, reason: Self.unavailableReason)
        }
        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty else {
            throw ToolError.missingArgument("query")
        }
        let limit = min(max(arguments["limit"]?.intValue ?? Self.defaultLimit, 1), Self.maxLimit)

        let hits = await dependencies.search(query, limit)
        guard !hits.isEmpty else {
            return "No memories match \"\(query)\"."
        }
        return hits.map { hit in
            var line = "- (\(hit.handle)) \(hit.body)"
            if let title = hit.collectionTitle {
                line += " — in \"\(title)\""
            }
            if hit.isSuperseded {
                line += " [superseded by a newer entry]"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
