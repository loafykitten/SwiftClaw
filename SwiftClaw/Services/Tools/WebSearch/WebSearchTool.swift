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
                lines.append("   \(snippet(from: result.description))")
            }

            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// Strips HTML tags Brave embeds in descriptions and caps snippet length.
    private func snippet(from description: String, maxLength: Int = 300) -> String {
        var text = description.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > maxLength else {
            return text
        }

        return String(text.prefix(maxLength)) + "…"
    }
}
