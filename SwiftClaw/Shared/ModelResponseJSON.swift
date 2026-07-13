import Foundation

/// Extracts and decodes the JSON object a model was asked to reply with,
/// tolerating markdown code fences and surrounding prose. Shared by the
/// quick-entry services so robustness fixes to the scanning land once, not
/// per feature.
nonisolated enum ModelResponseJSON {
    static func decode<T: Decodable>(_ type: T.Type, from response: String) -> T? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try raw, then fenced, then first {...} span.
        let candidates: [String] = [
            trimmed,
            fencedBody(of: trimmed) ?? "",
            firstJSONObject(in: trimmed) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            if let parsed = try? JSONDecoder().decode(T.self, from: Data(candidate.utf8)) {
                return parsed
            }
        }
        return nil
    }

    private static func fencedBody(of text: String) -> String? {
        guard let fenceStart = text.range(of: "```") else { return nil }
        let afterFence = text[fenceStart.upperBound...].drop { $0 != "\n" }.dropFirst()
        guard let fenceEnd = afterFence.range(of: "```") else { return nil }
        return String(afterFence[..<fenceEnd.lowerBound])
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
