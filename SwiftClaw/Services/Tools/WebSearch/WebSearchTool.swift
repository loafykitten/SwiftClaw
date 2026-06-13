import Foundation

/// Searches the web via the Brave Search API.
///
/// Returns only titles, URLs, and snippets — deliberately compact so results
/// don't blow up the model's context window.
struct WebSearchTool: Tool {
    let name = "web_search"
    let displayName = "Web Search"
    let description = """
        Search the web for current information. Returns a compact list of \
        results with title, URL, and a short snippet. Use specific queries \
        for best results.
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
            name: "count",
            type: .integer,
            description: "Number of results to return (1-10, default 5)."
        ),
    ]

    var isConfigured: Bool {
        !(Keychain.string(forKey: SettingsKeys.braveSearchAPIKey) ?? "").isEmpty
    }

    var isEnabled: Bool {
        SettingsStorage.isWebSearchEnabled()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let query = arguments["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.missingArgument("query")
        }

        let count = min(max(arguments["count"]?.intValue ?? 5, 1), 10)
        let results = try await BraveSearchClient.fromSettings().search(query: query, count: count)

        guard !results.isEmpty else {
            return "No results found for \"\(query)\"."
        }

        return results.enumerated().map { index, result in
            var lines = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)",
            ]

            if let age = result.age, !age.isEmpty {
                lines.append("   Age: \(age)")
            }

            if !result.description.isEmpty {
                lines.append("   \(WebSearchFormatter.snippet(from: result.description, maxLength: 300))")
            }

            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
