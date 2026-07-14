import Foundation

/// Byte-preserving, line-based handling of a leading `---` front matter
/// block (Jekyll/Obsidian style). Deliberately does **not** use a YAML
/// library: it never parses, re-serializes, or normalizes anything it
/// doesn't need to. Every operation either leaves a line's bytes completely
/// untouched or replaces/inserts exactly one line, so unknown keys,
/// comments, and any `---` appearing later in the document body (e.g. a
/// thematic break) are never touched.
nonisolated struct FrontMatterBlock: Equatable {
    /// The range of the entire block in the source, including the opening
    /// and closing `---` lines and the closing line's terminator (if any).
    let range: Range<String.Index>

    private let source: String
    /// The interior lines (between the fences), in original order. Each
    /// range covers the line's content only, excluding its terminator.
    private let lines: [Range<String.Index>]
    private let closingFenceStart: String.Index
    /// The line terminator style ("\n", "\r\n", or "\r") used by lines in
    /// this block, reused when appending a new key line.
    private let lineTerminator: String

    /// Parses a leading front matter block, if `source` starts with a line
    /// that is exactly `---` and a later line that is also exactly `---`
    /// closes it. Returns `nil` when there's no opening fence, or the
    /// opening fence is never closed (which is not treated as front matter).
    init?(source: String) {
        let rawLines = Self.rawLines(in: source)
        guard let first = rawLines.first, source[first.content] == "---" else { return nil }
        guard let closingOffset = rawLines.dropFirst().firstIndex(where: { source[$0.content] == "---" }) else {
            return nil
        }
        let closing = rawLines[closingOffset]

        self.source = source
        self.range = source.startIndex..<closing.terminatorEnd
        self.lines = rawLines[1..<closingOffset].map(\.content)
        self.closingFenceStart = closing.content.lowerBound
        self.lineTerminator = first.terminator.isEmpty ? "\n" : first.terminator
    }

    /// Reads a scalar `key: value` line's value (trimmed), or `nil` if no
    /// line for `key` exists. Values are returned raw — quote-stripping is
    /// only applied by `tags`, since this is not a YAML parser.
    func value(for key: String) -> String? {
        guard let lineRange = matchingLine(for: key) else { return nil }
        return Self.valueText(in: source, lineRange: lineRange)
    }

    /// Reads `tags:` in either inline form (`tags: [a, b]` or `tags: a, b`)
    /// or YAML dash-list form (`tags:` followed by `- a` / `- b` lines).
    var tags: [String] {
        guard let lineIndex = lines.firstIndex(where: { matchesKey($0, "tags") }) else { return [] }
        let inlineValue = Self.valueText(in: source, lineRange: lines[lineIndex])
        if !inlineValue.isEmpty {
            return Self.parseInlineList(inlineValue)
        }

        var result: [String] = []
        for lineRange in lines[(lineIndex + 1)...] {
            let trimmed = source[lineRange].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { break }
            let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            result.append(Self.stripQuotes(item))
        }
        return result
    }

    /// Returns the full document with `key`'s line replaced (if it already
    /// has one) or a new `key: value` line appended just before the closing
    /// fence. Only that single line's bytes ever change — every other byte
    /// in the source, including the fences, unknown keys, comments, and the
    /// document body, is preserved exactly.
    func settingValue(_ value: String, for key: String) -> String {
        var result = source
        if let lineRange = matchingLine(for: key) {
            result.replaceSubrange(lineRange, with: "\(key): \(value)")
        } else {
            result.insert(contentsOf: "\(key): \(value)\(lineTerminator)", at: closingFenceStart)
        }
        return result
    }

    // MARK: - Line matching

    private func matchingLine(for key: String) -> Range<String.Index>? {
        lines.first { matchesKey($0, key) }
    }

    private func matchesKey(_ lineRange: Range<String.Index>, _ key: String) -> Bool {
        let trimmed = source[lineRange].drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("\(key):")
    }

    private static func valueText(in source: String, lineRange: Range<String.Index>) -> String {
        let text = source[lineRange]
        guard let colon = text.firstIndex(of: ":") else { return "" }
        return text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func parseInlineList(_ value: String) -> [String] {
        var trimmed = value
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: ",")
            .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    // MARK: - Line splitting

    private struct RawLine {
        /// The line's content, excluding its terminator.
        let content: Range<String.Index>
        /// The terminator itself ("\n", "\r\n", "\r", or "" at end-of-file).
        let terminator: String
        /// The index just past the terminator (or equal to `content.upperBound` at end-of-file).
        let terminatorEnd: String.Index
    }

    /// Splits `source` into lines without losing terminator information, so
    /// each line's exact byte range (and its original line-ending style) is
    /// preserved. `\r\n` is a single `Character` under Swift's grapheme
    /// clustering, so a plain `Character`-level scan already treats it as
    /// one line terminator.
    private static func rawLines(in source: String) -> [RawLine] {
        var result: [RawLine] = []
        var idx = source.startIndex
        while idx < source.endIndex {
            var end = idx
            while end < source.endIndex {
                let character = source[end]
                if character == "\n" || character == "\r\n" || character == "\r" { break }
                end = source.index(after: end)
            }
            if end < source.endIndex {
                let terminator = String(source[end])
                let after = source.index(after: end)
                result.append(RawLine(content: idx..<end, terminator: terminator, terminatorEnd: after))
                idx = after
            } else {
                result.append(RawLine(content: idx..<end, terminator: "", terminatorEnd: end))
                idx = end
            }
        }
        return result
    }
}
