import Foundation

/// Whitespace-tokenized matching for the `.searchable` filters: every token
/// must appear (case/diacritic-insensitively) in at least one value.
nonisolated enum SearchQuery {
    /// Whether `text` contains anything worth filtering on.
    static func isActive(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    static func matches(_ text: String, in values: [String]) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }

        return tokens.allSatisfy { token in
            values.contains { $0.localizedStandardContains(token) }
        }
    }
}
