import Foundation
import SwiftUI

struct ChatInlineStyle: OptionSet {
    let rawValue: Int

    static let bold = ChatInlineStyle(rawValue: 1 << 0)
    static let italic = ChatInlineStyle(rawValue: 1 << 1)
    static let code = ChatInlineStyle(rawValue: 1 << 2)
    static let quote = ChatInlineStyle(rawValue: 1 << 3)
}

/// A contiguous span of text sharing one set of inline styles and an optional
/// link. The parser emits these once; SwiftUI and AppKit renderers consume them.
struct InlineRun {
    var text: String
    var style: ChatInlineStyle
    var link: URL?
}

enum ChatInlineMarkdownParser {
    static func runs(from text: String, citations: [Int: URL]) -> [InlineRun] {
        var runs: [InlineRun] = []
        appendParsed(text[...], activeStyle: [], link: nil, citations: citations, to: &runs)
        return runs
    }

    private static func appendParsed(
        _ text: Substring,
        activeStyle: ChatInlineStyle,
        link: URL?,
        citations: [Int: URL],
        to runs: inout [InlineRun]
    ) {
        var index = text.startIndex
        var plainStart = index

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else {
                return
            }

            runs.append(InlineRun(text: String(text[plainStart..<end]), style: activeStyle, link: link))
        }

        while index < text.endIndex {
            let remaining = text[index...]

            if remaining.hasPrefix("`"),
               let end = closingIndex(for: "`", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                runs.append(InlineRun(
                    text: String(text[text.index(after: index)..<end]),
                    style: activeStyle.union(.code),
                    link: link
                ))
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("**"),
               let end = closingIndex(for: "**", in: text, after: text.index(index, offsetBy: 2)) {
                flushPlain(upTo: index)
                appendParsed(
                    text[text.index(index, offsetBy: 2)..<end],
                    activeStyle: activeStyle.union(.bold),
                    link: link,
                    citations: citations,
                    to: &runs
                )
                index = text.index(end, offsetBy: 2)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("*"),
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               text[next] != "*",
               let end = closingSingleAsterisk(in: text, after: next) {
                flushPlain(upTo: index)
                appendParsed(
                    text[next..<end],
                    activeStyle: activeStyle.union(.italic),
                    link: link,
                    citations: citations,
                    to: &runs
                )
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("[") {
                if let markdownLink = markdownLink(in: text, at: index) {
                    flushPlain(upTo: index)
                    appendParsed(
                        markdownLink.label,
                        activeStyle: activeStyle,
                        link: markdownLink.url,
                        citations: citations,
                        to: &runs
                    )
                    index = markdownLink.end
                    plainStart = index
                    continue
                }

                if let citation = citationReference(in: text, at: index, citations: citations) {
                    flushPlain(upTo: index)
                    runs.append(InlineRun(text: citation.label, style: activeStyle, link: citation.url))
                    index = citation.end
                    plainStart = index
                    continue
                }
            }

            if remaining.hasPrefix("http://") || remaining.hasPrefix("https://"),
               let bareLink = bareLink(in: text, at: index) {
                flushPlain(upTo: index)
                runs.append(InlineRun(text: String(bareLink.label), style: activeStyle, link: bareLink.url))
                index = bareLink.end
                plainStart = index
                continue
            }

            if remaining.hasPrefix("\""),
               let end = closingIndex(for: "\"", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                let quoteStyle = activeStyle.union(.quote)
                runs.append(InlineRun(text: "\"", style: quoteStyle, link: link))
                appendParsed(
                    text[text.index(after: index)..<end],
                    activeStyle: quoteStyle,
                    link: link,
                    citations: citations,
                    to: &runs
                )
                runs.append(InlineRun(text: "\"", style: quoteStyle, link: link))
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("“"),
               let end = closingIndex(for: "”", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                let quoteStyle = activeStyle.union(.quote)
                runs.append(InlineRun(text: "“", style: quoteStyle, link: link))
                appendParsed(
                    text[text.index(after: index)..<end],
                    activeStyle: quoteStyle,
                    link: link,
                    citations: citations,
                    to: &runs
                )
                runs.append(InlineRun(text: "”", style: quoteStyle, link: link))
                index = text.index(after: end)
                plainStart = index
                continue
            }

            index = text.index(after: index)
        }

        flushPlain(upTo: text.endIndex)
    }

    private static func markdownLink(
        in text: Substring,
        at start: String.Index
    ) -> (label: Substring, url: URL, end: String.Index)? {
        let labelStart = text.index(after: start)
        guard let labelEnd = closingIndex(for: "]", in: text, after: labelStart) else {
            return nil
        }

        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else {
            return nil
        }

        let urlStart = text.index(after: afterLabel)
        guard let urlEnd = closingIndex(for: ")", in: text, after: urlStart) else {
            return nil
        }

        let urlText = text[urlStart..<urlEnd].trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText), url.scheme != nil else {
            return nil
        }

        return (text[labelStart..<labelEnd], url, text.index(after: urlEnd))
    }

    private static func citationReference(
        in text: Substring,
        at start: String.Index,
        citations: [Int: URL]
    ) -> (label: String, url: URL, end: String.Index)? {
        var index = text.index(after: start)
        var digits = ""

        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }

        guard !digits.isEmpty,
              index < text.endIndex,
              text[index] == "]",
              let number = Int(digits),
              let url = citations[number] else {
            return nil
        }

        return ("[\(digits)]", url, text.index(after: index))
    }

    private static func bareLink(
        in text: Substring,
        at start: String.Index
    ) -> (label: Substring, url: URL, end: String.Index)? {
        var end = start
        while end < text.endIndex,
              !text[end].isWhitespace,
              text[end] != "<",
              text[end] != ">" {
            end = text.index(after: end)
        }

        var candidate = text[start..<end]
        while let last = candidate.last, ".,;:!?)]}\"'".contains(last) {
            candidate = candidate.dropLast()
        }

        guard candidate.count > "https://".count,
              let url = URL(string: String(candidate)) else {
            return nil
        }

        return (candidate, url, candidate.endIndex)
    }

    static func attributedString(
        runs: [InlineRun],
        baseFont: Font,
        codeFont: Font,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color,
        linkAccent: Color
    ) -> AttributedString {
        var result = AttributedString()

        for run in runs {
            var segment = AttributedString(run.text)
            segment.font = swiftFont(for: run.style, baseFont: baseFont, codeFont: codeFont)

            if run.link != nil {
                segment.foregroundColor = linkAccent
                segment.underlineStyle = .single
                segment.link = run.link
            } else if run.style.contains(.code) {
                segment.foregroundColor = codeAccent
                segment.backgroundColor = codeAccent.opacity(0.12)
            } else if run.style.contains(.quote) {
                segment.foregroundColor = quoteAccent
            } else {
                segment.foregroundColor = defaultForeground
            }

            result += segment
        }

        return result
    }

    private static func swiftFont(for style: ChatInlineStyle, baseFont: Font, codeFont: Font) -> Font {
        var font = style.contains(.code) ? codeFont : baseFont

        if style.contains(.bold) {
            font = font.weight(.semibold)
        }

        if style.contains(.italic) {
            font = font.italic()
        }

        return font
    }

    private static func closingIndex(
        for marker: String,
        in text: Substring,
        after start: String.Index
    ) -> String.Index? {
        var index = start

        while index < text.endIndex {
            if text[index...].hasPrefix(marker) {
                return index
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func closingSingleAsterisk(in text: Substring, after start: String.Index) -> String.Index? {
        var index = start

        while index < text.endIndex {
            if text[index] == "*" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] != "*" {
                    return index
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}
