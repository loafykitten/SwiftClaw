import Foundation

nonisolated enum WebSearchFormatter {
    /// Strips HTML tags Brave embeds in descriptions and caps snippet length.
    static func snippet(from description: String, maxLength: Int) -> String {
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
