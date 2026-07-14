import Foundation
import Markdown

/// A parsed markdown source, shared across features (not a Notes type).
/// Exposes source ranges, a heading outline, and "excluded ranges" — fenced
/// and indented code blocks, inline code spans, and leading front matter —
/// so scanners (wikilink/tag extraction, chunking) can skip over content
/// that only looks like markup syntax without duplicating a parser.
struct MarkdownDocument {
    struct HeadingEntry: Equatable {
        let level: Int
        let text: String
        let range: Range<String.Index>
    }

    let source: String
    let frontMatter: FrontMatterBlock?
    let headings: [HeadingEntry]
    /// Ranges that scanners should treat as opaque: leading front matter,
    /// fenced/indented code blocks, and inline code spans. Sorted by
    /// `lowerBound`; may be empty.
    let excludedRanges: [Range<String.Index>]

    init(source: String) {
        self.source = source
        let frontMatter = FrontMatterBlock(source: source)
        self.frontMatter = frontMatter

        // Parse only the body, past any front matter — handing YAML-ish
        // front matter lines to cmark risks misparses (e.g. a `key: value`
        // line immediately followed by the closing `---` reads as a Setext
        // heading underline), which would otherwise leak bogus headings.
        let bodyStart = frontMatter?.range.upperBound ?? source.startIndex
        let bodyText = String(source[bodyStart...])
        let bodyByteOffset = source.utf8.distance(from: source.utf8.startIndex, to: bodyStart)

        let document = Document(parsing: bodyText, options: [])
        let converter = MarkdownDocument.OffsetConverter(bodyText: bodyText, fullSource: source, bodyByteOffset: bodyByteOffset)

        var collector = Collector(converter: converter)
        collector.visit(document)

        var excluded = collector.excludedRanges
        if let frontMatter {
            excluded.append(frontMatter.range)
        }
        self.excludedRanges = excluded.sorted { $0.lowerBound < $1.lowerBound }
        self.headings = collector.headings
    }

    /// Whether `index` falls inside any excluded range (front matter, code
    /// block, or inline code span).
    func isExcluded(_ index: String.Index) -> Bool {
        excludedRanges.contains { $0.contains(index) }
    }

    /// Whether `range` overlaps any excluded range at all — useful for
    /// scanners deciding whether a candidate match (e.g. a `[[wikilink]]`)
    /// needs to be discarded.
    func isExcluded(_ range: Range<String.Index>) -> Bool {
        excludedRanges.contains { $0.overlaps(range) || $0 == range }
    }

    // MARK: - Source location -> String.Index

    /// `swift-markdown`'s `SourceLocation.column` is a 1-based UTF-8 byte
    /// offset from the start of its line, not a `String.Index` or character
    /// offset. This converts a `SourceRange` from the parsed tree back into
    /// a `Range<String.Index>` over `source`, so downstream code (styling,
    /// chunking) never has to reason about line/column pairs.
    private struct OffsetConverter {
        /// The full original source — `SourceLocation`s from parsing
        /// `bodyText` are shifted by `bodyByteOffset` before indexing here,
        /// so returned indices are always valid for the full document.
        private let fullSource: String
        private let bodyByteOffset: Int
        /// UTF-8 byte offset of the start of each line of `bodyText`,
        /// indexed by `line - 1`.
        private let lineStartUTF8Offsets: [Int]

        init(bodyText: String, fullSource: String, bodyByteOffset: Int) {
            self.fullSource = fullSource
            self.bodyByteOffset = bodyByteOffset
            var offsets = [0]
            var offset = 0
            for byte in bodyText.utf8 {
                offset += 1
                if byte == 0x0A {
                    offsets.append(offset)
                }
            }
            self.lineStartUTF8Offsets = offsets
        }

        func index(for location: SourceLocation) -> String.Index? {
            let lineIndex = location.line - 1
            guard lineIndex >= 0, lineIndex < lineStartUTF8Offsets.count else { return nil }
            let byteOffset = bodyByteOffset + lineStartUTF8Offsets[lineIndex] + (location.column - 1)
            guard byteOffset >= 0, byteOffset <= fullSource.utf8.count else { return nil }
            return fullSource.utf8.index(fullSource.utf8.startIndex, offsetBy: byteOffset)
        }

        func range(for sourceRange: SourceRange) -> Range<String.Index>? {
            guard let lower = index(for: sourceRange.lowerBound),
                  let upper = index(for: sourceRange.upperBound),
                  lower <= upper
            else { return nil }
            return lower..<upper
        }
    }

    private struct Collector: MarkupWalker {
        let converter: OffsetConverter
        var headings: [HeadingEntry] = []
        var excludedRanges: [Range<String.Index>] = []

        mutating func visitHeading(_ heading: Heading) {
            if let sourceRange = heading.range, let range = converter.range(for: sourceRange) {
                headings.append(HeadingEntry(level: heading.level, text: heading.plainText, range: range))
            }
            // Headings can't contain code blocks, but a nested inline code
            // span (e.g. "## Using `code`") still needs to be excluded.
            descendInto(heading)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            if let sourceRange = codeBlock.range, let range = converter.range(for: sourceRange) {
                excludedRanges.append(range)
            }
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            if let sourceRange = inlineCode.range, let range = converter.range(for: sourceRange) {
                excludedRanges.append(range)
            }
        }
    }
}
