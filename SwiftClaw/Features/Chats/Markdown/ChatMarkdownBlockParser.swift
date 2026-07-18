import Foundation

enum ChatMarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
}

struct ChatMarkdownPresentation: Sendable, Equatable {
    let blocks: [ChatMarkdownBlock]
    let citations: [Int: URL]
}

@MainActor
final class ChatMarkdownPresentationCache {
    static let shared = ChatMarkdownPresentationCache()

    private final class Entry {
        let presentation: ChatMarkdownPresentation

        init(_ presentation: ChatMarkdownPresentation) {
            self.presentation = presentation
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 100
    }

    func presentation(for content: String) -> ChatMarkdownPresentation {
        // Exact source equality is the invalidation key; any content edit is
        // a cache miss, and NSCache bounds retained transcript presentations.
        let key = content as NSString
        if let cached = cache.object(forKey: key) {
            return cached.presentation
        }
        let presentation = ChatMarkdownBlockParser.presentation(from: content)
        cache.setObject(Entry(presentation), forKey: key)
        return presentation
    }
}

enum ChatMarkdownBlockParser {
    static func presentation(from content: String) -> ChatMarkdownPresentation {
        let lines = content.components(separatedBy: .newlines)
        return ChatMarkdownPresentation(
            blocks: blocks(from: content, lines: lines),
            citations: citationLinks(from: lines)
        )
    }

    static func blocks(from content: String) -> [ChatMarkdownBlock] {
        blocks(from: content, lines: content.components(separatedBy: .newlines))
    }

    private static func blocks(from content: String, lines: [String]) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else {
                return
            }

            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else {
                return
            }

            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quoteLines.append(quoteText(from: trimmed))
                continue
            }

            flushQuote()
            paragraphLines.append(line)
        }

        flushParagraph()
        flushQuote()

        return blocks.isEmpty ? [.paragraph(content)] : blocks
    }

    /// Builds a source-number -> URL map from the final Sources section only.
    static func citationLinks(from content: String) -> [Int: URL] {
        citationLinks(from: content.components(separatedBy: .newlines))
    }

    private static func citationLinks(from lines: [String]) -> [Int: URL] {
        guard let sourceLines = finalSourcesSectionLines(from: lines) else {
            return [:]
        }

        var links: [Int: URL] = [:]

        for line in sourceLines {
            guard let source = numberedSource(from: line), links[source.number] == nil else {
                continue
            }

            links[source.number] = source.url
        }

        return links
    }

    private static func finalSourcesSectionLines(from lines: [String]) -> ArraySlice<String>? {
        guard let sourcesIndex = lines.indices.last(where: { isSourcesSectionTitle(lines[$0]) }) else {
            return nil
        }

        let laterLines = lines[lines.index(after: sourcesIndex)...]
        guard laterLines.contains(where: { numberedSource(from: $0) != nil }) else {
            return nil
        }

        let laterMarkdownHeadings = laterLines.contains { line in
            markdownHeadingTitle(from: line) != nil
        }
        guard !laterMarkdownHeadings else {
            return nil
        }

        return laterLines
    }

    private static func numberedSource(from line: String) -> (number: Int, url: URL)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard let dotIndex = trimmed.firstIndex(of: "."),
              dotIndex != trimmed.startIndex,
              trimmed[..<dotIndex].allSatisfy(\.isNumber),
              let number = Int(trimmed[..<dotIndex]) else {
            return nil
        }

        let afterDot = trimmed.index(after: dotIndex)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else {
            return nil
        }

        guard let urlRange = trimmed.range(of: "https://")
                ?? trimmed.range(of: "http://") else {
            return nil
        }

        var urlText = trimmed[urlRange.lowerBound...]
        if let whitespace = urlText.firstIndex(where: \.isWhitespace) {
            urlText = urlText[..<whitespace]
        }
        while let last = urlText.last, ".,;:!?)]}\"'".contains(last) {
            urlText = urlText.dropLast()
        }

        guard let url = URL(string: String(urlText)) else {
            return nil
        }

        return (number, url)
    }

    private static func isSourcesSectionTitle(_ line: String) -> Bool {
        let title = markdownHeadingTitle(from: line) ?? line.trimmingCharacters(in: .whitespaces)
        let normalized = title.trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
        return normalized.caseInsensitiveCompare("Sources") == .orderedSame
    }

    private static func markdownHeadingTitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let markerCount = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else {
            return nil
        }

        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: markerCount)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd].isWhitespace else {
            return nil
        }

        let textStart = trimmed.index(after: markerEnd)
        let text = trimmed[textStart...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(markerCount) else {
            return nil
        }

        let markerEnd = line.index(line.startIndex, offsetBy: markerCount)
        guard markerEnd < line.endIndex, line[markerEnd].isWhitespace else {
            return nil
        }

        let textStart = line.index(after: markerEnd)
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return nil
        }

        return (markerCount, text)
    }

    private static func quoteText(from line: String) -> String {
        var text = line.dropFirst()

        if text.first == " " {
            text = text.dropFirst()
        }

        return String(text)
    }
}
