import Foundation

/// Whitespace-tokenized matching for the `.searchable` filters: every token
/// must appear (case/diacritic-insensitively) in at least one value.
nonisolated enum SearchQuery {
    /// Whether `text` contains anything worth filtering on.
    static func isActive(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    static func matches(_ text: String, in values: [String]) -> Bool {
        Compiled(text).matches(in: values)
    }

    /// A query tokenized once, for matching against many candidates —
    /// avoids re-splitting `text` for every row of a filtered collection.
    struct Compiled {
        let tokens: [Substring]

        init(_ text: String) {
            tokens = text.split(whereSeparator: \.isWhitespace)
        }

        var isActive: Bool { !tokens.isEmpty }

        func matches(in values: [String]) -> Bool {
            tokens.allSatisfy { token in
                values.contains { $0.localizedStandardContains(token) }
            }
        }
    }
}
