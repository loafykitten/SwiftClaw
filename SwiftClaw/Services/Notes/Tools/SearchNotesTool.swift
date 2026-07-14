import Foundation

/// Hybrid (FTS + embedding) search over the user's notes vault. Always
/// offered when Notes is enabled and a vault/index exist — reads are always
/// allowed, matching `WebSearchTool`'s posture — and vanishes from every
/// chat the moment Notes is disabled via `ToolRegistry.availableTools`.
struct SearchNotesTool: Tool {
    static let defaultLimit = 8
    static let maxLimit = 20

    /// Seam so gating/search can be exercised with stubs in tests instead of
    /// the live `NotesFeatureModel` singleton. The closures are `@MainActor`
    /// because the model they wrap is; building `.live`'s closure values
    /// here doesn't run any MainActor code, only *calling* them does.
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
        var search: @MainActor @Sendable (_ query: String, _ limit: Int) async throws -> [SearchHit]

        static let live = Dependencies(
            isAvailable: { NotesFeatureModel.shared.isAvailableForReadTools },
            search: { query, limit in
                try await NotesFeatureModel.shared.searchNotesForTool(query: query, limit: limit)
            }
        )
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    let name = "search_notes"
    let displayName = "Search Notes"
    let description = """
        Search the user's notes vault for content matching a query. Returns a \
        compact list of cited hits, each formatted as \
        "[[note: relative/path.md § Heading]]" followed by a short snippet. \
        Use read_note with the cited path to fetch a hit's full content.
        """
    let systemImage = "magnifyingglass"

    let parameters = [
        ToolParameter(
            name: "query",
            type: .string,
            description: "The search query.",
            isRequired: true
        ),
        ToolParameter(
            name: "limit",
            type: .integer,
            description: "Number of hits to return (1-20, default 8)."
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

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard await dependencies.isAvailable() else {
            throw ToolError.notConfigured(
                toolName: displayName,
                reason: "Notes is disabled, or no vault/index is configured."
            )
        }

        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty else {
            throw ToolError.missingArgument("query")
        }

        let limit = min(max(arguments["limit"]?.intValue ?? Self.defaultLimit, 1), Self.maxLimit)

        let hits: [SearchHit]
        do {
            hits = try await dependencies.search(query, limit)
        } catch let toolError as ToolError {
            // The model facade throws `ToolError.notConfigured` directly when
            // a vault reset/switch invalidates an in-flight search — that
            // must reach the caller as-is, not get flattened into a generic
            // `executionFailed`.
            throw toolError
        } catch {
            throw ToolError.executionFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }

        guard !hits.isEmpty else {
            return "No notes found matching \"\(query)\"."
        }

        return hits.map(Self.citation).joined(separator: "\n\n")
    }

    private static func citation(for hit: SearchHit) -> String {
        let reference = hit.headingPath.isEmpty
            ? "[[note: \(hit.document.sourceID)]]"
            : "[[note: \(hit.document.sourceID) § \(hit.headingPath)]]"
        return "\(reference)\n\(hit.snippet)"
    }
}
