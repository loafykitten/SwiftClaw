import Foundation

/// Converts ordinary web HTML into bounded, readable plain text without a
/// parser dependency. This is intentionally a readability heuristic, not a
/// standards-complete HTML implementation.
nonisolated struct ContentExtractor: Sendable {
    private static let maximumInputCharacters = 2_000_000
    private static let ignoredTags: Set<String> = [
        "script", "style", "nav", "header", "footer", "aside", "form",
        "noscript", "svg", "iframe",
    ]
    private static let blockTags: Set<String> = [
        "address", "article", "blockquote", "br", "dd", "div", "dl", "dt",
        "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
        "li", "main", "ol", "p", "pre", "section", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "ul",
    ]
    private static let candidateTags: Set<String> = ["div", "section"]
    private static let preferredTags: Set<String> = ["article", "main"]
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]

    func extractMainText(fromHTML html: String) -> String {
        let boundedHTML = String(html.prefix(Self.maximumInputCharacters))
        var fragments = [String]()
        var visibleCharacterCount = 0
        var ignoredStack = [String]()
        var containers = [OpenContainer]()
        var candidates = [Candidate]()

        scan(boundedHTML) { token in
            switch token {
            case .text(let text):
                guard ignoredStack.isEmpty else {
                    return
                }
                // Raw newlines in HTML text are ordinary whitespace; only the
                // "\n" markers appended at block-tag boundaries may become
                // paragraph breaks in `normalizedText`.
                let decoded = Self.flattenedInlineWhitespace(
                    in: Self.decodeEntities(in: text)
                )
                fragments.append(decoded)
                visibleCharacterCount += decoded.count

            case .tag(let name, let isClosing, let isSelfClosing):
                if !ignoredStack.isEmpty {
                    if isClosing {
                        if let match = ignoredStack.lastIndex(of: name) {
                            ignoredStack.removeSubrange(match...)
                        }
                    } else if Self.ignoredTags.contains(name), !isSelfClosing {
                        ignoredStack.append(name)
                    }
                    return
                }

                if Self.ignoredTags.contains(name) {
                    if !isClosing, !isSelfClosing {
                        ignoredStack.append(name)
                    }
                    return
                }

                if isClosing {
                    if let match = containers.lastIndex(where: { $0.tag == name }) {
                        for container in containers[match...].reversed() {
                            candidates.append(Candidate(
                                range: container.startFragment..<fragments.count,
                                characterCount: visibleCharacterCount - container.startCharacterCount,
                                isPreferred: container.isPreferred
                            ))
                        }
                        containers.removeSubrange(match...)
                    }
                    if Self.blockTags.contains(name) {
                        fragments.append("\n")
                    }
                    return
                }

                if Self.blockTags.contains(name) {
                    fragments.append("\n")
                }

                let isPreferred = Self.preferredTags.contains(name)
                if isPreferred || Self.candidateTags.contains(name) {
                    containers.append(OpenContainer(
                        tag: name,
                        startFragment: fragments.count,
                        startCharacterCount: visibleCharacterCount,
                        isPreferred: isPreferred
                    ))
                }

                if isSelfClosing, let container = containers.last, container.tag == name {
                    candidates.append(Candidate(
                        range: container.startFragment..<fragments.count,
                        characterCount: 0,
                        isPreferred: container.isPreferred
                    ))
                    containers.removeLast()
                }
            }
        }

        for container in containers.reversed() {
            candidates.append(Candidate(
                range: container.startFragment..<fragments.count,
                characterCount: visibleCharacterCount - container.startCharacterCount,
                isPreferred: container.isPreferred
            ))
        }

        let preferred = candidates.filter(\.isPreferred)
        let selection = (preferred.isEmpty ? candidates : preferred)
            .max { $0.characterCount < $1.characterCount }
        let selectedFragments = selection.map { Array(fragments[$0.range]) } ?? fragments
        return Self.normalizedText(from: selectedFragments.joined())
    }

    func extractTitle(fromHTML html: String) -> String? {
        let boundedHTML = String(html.prefix(Self.maximumInputCharacters))
        for tag in ["title", "h1"] {
            if let value = firstText(inTag: tag, html: boundedHTML), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private struct OpenContainer {
        let tag: String
        let startFragment: Int
        let startCharacterCount: Int
        let isPreferred: Bool
    }

    private struct Candidate {
        let range: Range<Int>
        let characterCount: Int
        let isPreferred: Bool
    }

    private enum Token {
        case text(String)
        case tag(name: String, isClosing: Bool, isSelfClosing: Bool)
    }

    private func firstText(inTag target: String, html: String) -> String? {
        var depth = 0
        var fragments = [String]()
        var result: String?

        scan(html) { token in
            guard result == nil else {
                return
            }

            switch token {
            case .text(let text) where depth > 0:
                fragments.append(Self.decodeEntities(in: text))
            case .text:
                break
            case .tag(let name, let isClosing, let isSelfClosing) where name == target:
                if isClosing, depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        result = Self.normalizedText(from: fragments.joined(separator: " "))
                    }
                } else if !isClosing, !isSelfClosing {
                    depth += 1
                }
            case .tag:
                break
            }
        }

        if result == nil, depth > 0 {
            result = Self.normalizedText(from: fragments.joined(separator: " "))
        }
        return result
    }

    /// Walks tags and text in one pass. Malformed trailing tags are discarded,
    /// and the input cap bounds both memory use and scan time.
    private func scan(_ html: String, visit: (Token) -> Void) {
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let nextTag = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                visit(.text(String(html[cursor..<nextTag])))
                cursor = nextTag
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                if let end = html[cursor...].range(of: "-->")?.upperBound {
                    cursor = end
                } else {
                    return
                }
                continue
            }

            guard let close = html[cursor...].firstIndex(of: ">") else {
                return
            }

            let contentStart = html.index(after: cursor)
            let rawContent = html[contentStart..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = html.index(after: close)

            guard !rawContent.isEmpty,
                  !rawContent.hasPrefix("!"),
                  !rawContent.hasPrefix("?") else {
                continue
            }

            var tagContent = rawContent[...]
            let isClosing = tagContent.first == "/"
            if isClosing {
                tagContent = tagContent.dropFirst()
                    .drop(while: { $0.isWhitespace })
            }

            let name = String(tagContent.prefix { character in
                character.isLetter || character.isNumber || character == ":" || character == "-"
            }).lowercased()
            guard !name.isEmpty else {
                continue
            }

            let isSelfClosing = rawContent.hasSuffix("/") || Self.voidTags.contains(name)
            visit(.tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing))
        }
    }

    private static func decodeEntities(in text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == "&" else {
                output.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }

            var end = text.index(after: cursor)
            var scanned = 0
            while end < text.endIndex, text[end] != ";", scanned < 12 {
                end = text.index(after: end)
                scanned += 1
            }

            guard end < text.endIndex, text[end] == ";" else {
                output.append("&")
                cursor = text.index(after: cursor)
                continue
            }

            let nameStart = text.index(after: cursor)
            let name = String(text[nameStart..<end])
            if let decoded = decodedEntity(named: name) {
                output.append(decoded)
                cursor = text.index(after: end)
            } else {
                output.append("&")
                cursor = text.index(after: cursor)
            }
        }

        return output
    }

    private static func decodedEntity(named name: String) -> Character? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        default:
            guard name.hasPrefix("#") else {
                return nil
            }

            let digits: Substring
            let radix: Int
            if name.dropFirst().lowercased().hasPrefix("x") {
                digits = name.dropFirst(2)[...]
                radix = 16
            } else {
                digits = name.dropFirst()[...]
                radix = 10
            }

            guard let value = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(value) else {
                return nil
            }
            return Character(scalar)
        }
    }

    private static func flattenedInlineWhitespace(in text: String) -> String {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return text
        }
        return String(text.map { $0 == "\n" || $0 == "\r" ? " " : $0 })
    }

    private static func normalizedText(from text: String) -> String {
        var lines = [String]()
        var line = String()
        var pendingSpace = false

        func finishLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
            line.removeAll(keepingCapacity: true)
            pendingSpace = false
        }

        for character in text {
            if character == "\n" || character == "\r" {
                finishLine()
            } else if character.isWhitespace {
                pendingSpace = !line.isEmpty
            } else {
                if pendingSpace {
                    line.append(" ")
                }
                line.append(character)
                pendingSpace = false
            }
        }
        finishLine()

        return lines.joined(separator: "\n\n")
    }
}
