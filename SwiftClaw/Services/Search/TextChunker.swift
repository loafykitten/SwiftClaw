import Foundation

/// Splits plain text into search-index chunks at heading boundaries,
/// further splitting oversized sections at line boundaries so no chunk
/// meaningfully exceeds `maxChunkSize` UTF-8 bytes. Source-agnostic and
/// pure — no markdown parser dependency, no I/O.
///
/// Every returned chunk's `byteStart`/`byteEnd` are exact UTF-8 byte offsets
/// into the original `text`, chosen only at line boundaries, so
/// `Array(text.utf8)[byteStart..<byteEnd]` re-slices to precisely the
/// chunk's `content` (Unicode-safe: multi-byte characters are never split
/// mid-sequence, since cuts only ever land on `\n` boundaries). Chunks never
/// overlap; whitespace-only spans between chunks are simply omitted, not
/// represented.
nonisolated enum TextChunker {
    struct Chunk: Sendable, Equatable {
        let headingPath: String
        let byteStart: Int
        let byteEnd: Int
        let content: String
    }

    static let defaultMaxChunkSize = 1500

    static func chunk(_ text: String, maxChunkSize: Int = defaultMaxChunkSize) -> [Chunk] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }

        let lines = lineRanges(in: bytes)
        var headingStack: [String] = []
        var chunks: [Chunk] = []
        var pendingStart: Int?
        var pendingHeadingPath = ""

        func flush(end: Int) {
            defer { pendingStart = nil }
            guard let start = pendingStart, end > start else { return }
            let content = String(decoding: bytes[start..<end], as: UTF8.self)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            chunks.append(Chunk(headingPath: pendingHeadingPath, byteStart: start, byteEnd: end, content: content))
        }

        for line in lines {
            let lineText = String(decoding: bytes[line], as: UTF8.self)
            if let heading = headingMatch(lineText) {
                flush(end: line.lowerBound)
                while headingStack.count >= heading.level {
                    headingStack.removeLast()
                }
                headingStack.append(heading.title)
                pendingHeadingPath = headingStack.joined(separator: " > ")
                pendingStart = line.lowerBound
                continue
            }

            if pendingStart == nil {
                pendingStart = line.lowerBound
            }
            let currentSize = line.lowerBound - (pendingStart ?? line.lowerBound)
            if currentSize > 0, currentSize + line.count > maxChunkSize {
                flush(end: line.lowerBound)
                pendingStart = line.lowerBound
            }
        }
        flush(end: bytes.count)
        return chunks
    }

    /// Byte ranges of each line, including its trailing `\n` (if any) so
    /// consecutive ranges tile the buffer with no gaps and no overlap.
    private static func lineRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var lineStart = 0
        for index in bytes.indices where bytes[index] == UInt8(ascii: "\n") {
            ranges.append(lineStart..<(index + 1))
            lineStart = index + 1
        }
        if lineStart < bytes.count {
            ranges.append(lineStart..<bytes.count)
        }
        return ranges
    }

    /// Matches ATX-style headings (`# Title` … `###### Title`) — a bare
    /// `#` with no following space is not a heading.
    private static func headingMatch(_ line: String) -> (level: Int, title: String)? {
        var trimmed = Substring(line)
        while let last = trimmed.last, last == "\n" || last == "\r" {
            trimmed.removeLast()
        }
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#" {
            level += 1
            index = trimmed.index(after: index)
        }
        guard level <= 6, index < trimmed.endIndex, trimmed[index] == " " else { return nil }
        let title = trimmed[index...].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }
}
